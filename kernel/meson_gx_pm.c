// SPDX-License-Identifier: GPL-2.0
/*
 * Amlogic Meson GX Power Management (deep suspend-to-RAM)
 * Порт RFC-драйвера Neil Armstrong (Baylibre, 2016). GX SoC входит в
 * SUSPEND_MEM через нестандартный параметр PSCI CPU_SUSPEND (0x10000),
 * который обрабатывает секьюрная прошивка (BL31/BL301). h96 05.09.2026.
 *
 * Optional "peripheral-power-gpios" in the pm node: the line is held high while
 * running and lowered in .suspend. The H96 device tree does NOT provide it, so
 * this path is inactive; which rail (if any) the aftermarket fan uses is not
 * established, and no GPIO is assumed here.
 */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/io.h>
#include <linux/platform_device.h>
#include <linux/suspend.h>
#include <linux/pm.h>
#include <linux/gpio/consumer.h>
#include <linux/arm-smccc.h>
#include <linux/reboot.h>
#include <linux/notifier.h>
#include <linux/input.h>
#include <linux/scpi_protocol.h>
#include <linux/netdevice.h>
#include <linux/rtnetlink.h>
#include <linux/workqueue.h>
#include <net/net_namespace.h>
#include <uapi/linux/psci.h>
#include <asm/suspend.h>

#define MESON_SUSPEND_PARAM 0x0010000

/*
 * h96 0042 (24.09.2026): IR wake from deep suspend.
 * In CPU_SUSPEND 0x10000 the SCP firmware (BL301, scp_task/scp_remote.c) sets
 * the AO IR decoder to hardware NEC itself and compares each frame with its
 * built-in power keys and with usr_pwr_key. The vendor kernel sets usr_pwr_key
 * with SCPI_CMD_SET_USR_DATA (0x20) from client SCPI_CL_REMOTE (5); the first
 * data word is the frame as the decoder stores it: ~cmd<<24 | cmd<<16 |
 * ~addr<<8 | addr. The owner's remote sends NEC 0x0140 (addr 0x01, cmd 0x40 =
 * KEY_POWER) -> 0xbf40fe01. 0 disables the handover (and remote standby).
 * BL301 consumes the waking frame, so Android never sees a key: after a real
 * resume KEY_WAKEUP is reported here to switch the screen back on.
 * If the handover fails, or the wake input could not be registered, suspend is
 * refused: an enabled remote standby must never enter an unwakeable sleep.
 */
#define MESON_SCPI_CL_REMOTE		5

static unsigned int ir_wake_key = 0xbf40fe01;
module_param(ir_wake_key, uint, 0644);
MODULE_PARM_DESC(ir_wake_key, "IR frame that wakes the SoC from deep suspend (BL301 usr_pwr_key), 0 = off");

/*
 * h96 0043: BL301 detect_key() also wakes by its own timer: before waiting it
 * reads AO_DEBUG_REG2 (AO base + 0x2a*4) and, if non-zero, wakes after that many
 * seconds (AUTO_WAKEUP). Test aid for unattended suspend/resume cycles; written
 * at suspend prepare, cleared after resume. 0 = off (default).
 */
#define MESON_AO_DEBUG_REG2		0xc81000a8
static unsigned int auto_wake_s;
module_param(auto_wake_s, uint, 0644);
MODULE_PARM_DESC(auto_wake_s, "test: BL301 timer wake after N seconds of deep suspend (0 = off)");
static void __iomem *meson_gx_ao_dbg2;

static struct input_dev *meson_gx_wake_input;
static bool meson_gx_wake_input_ok;
static bool meson_gx_really_slept;
static u32 meson_gx_wake_key_buf;	/* static: the mailbox copies it in tx_prepare */

/*
 * h96 0042: after deep suspend the RGMII PHY (RTL8211F) stays without carrier -
 * stmmac's resume does not bring it back, a full close/open of the interface
 * does (measured: "Link is Up - 1Gbps/Full" 2.6 s after down/up). Do that once
 * per real resume, from a work item (needs rtnl, may sleep), only for an
 * interface that is administratively up; a pending run is cancelled before the
 * next suspend.
 */
static char *resume_bounce_netdev = "eth0";
module_param(resume_bounce_netdev, charp, 0644);
MODULE_PARM_DESC(resume_bounce_netdev, "network interface to close/open after deep suspend (empty = none)");

static void meson_gx_netdev_bounce(struct work_struct *work)
{
	struct net_device *nd;
	int ret;

	if (!resume_bounce_netdev || !resume_bounce_netdev[0])
		return;
	nd = dev_get_by_name(&init_net, resume_bounce_netdev);
	if (!nd)
		return;
	rtnl_lock();
	if (netif_running(nd)) {
		dev_close(nd);
		ret = dev_open(nd, NULL);
		if (ret)
			pr_err("h96 pm: %s reopen after resume failed: %d\n",
			       nd->name, ret);
		else
			pr_info("h96 pm: %s reopened after resume\n", nd->name);
	}
	rtnl_unlock();
	dev_put(nd);
}
static DECLARE_WORK(meson_gx_netdev_work, meson_gx_netdev_bounce);

/*
 * h96 0023 (08.09.2026): vendor power-off preparation. The stock GXBB/GXM
 * "aml, restart" driver calls Amlogic SiP 0x82000042(1) ("suspend reason =
 * poweroff") before PSCI SYSTEM_OFF. Mirrored here as POWER_OFF_PREPARE.
 * Measured 24.09: the firmware accepts it (a0=0) but still restarts the board
 * a few seconds after "reboot: Power down". poweroff_sip=0 disables it.
 */
#define MESON_SIP_SUSPEND_REASON	0x82000042
#define MESON_SUSPEND_REASON_POWEROFF	1

static bool poweroff_sip = true;
module_param(poweroff_sip, bool, 0644);
MODULE_PARM_DESC(poweroff_sip, "send Amlogic SiP 0x82000042(1) before SYSTEM_OFF (stock poweroff handshake)");

static int meson_gx_poweroff_prepare(struct sys_off_data *data)
{
	struct arm_smccc_res res;

	if (!poweroff_sip)
		return NOTIFY_DONE;
	arm_smccc_smc(MESON_SIP_SUSPEND_REASON, MESON_SUSPEND_REASON_POWEROFF,
		      0, 0, 0, 0, 0, 0, &res);
	pr_info("h96 pm: poweroff prepare SMC 0x82000042(1) -> a0=0x%lx\n", res.a0);
	return NOTIFY_DONE;
}

static struct gpio_desc *meson_gx_periph_pwr;

static int meson_gx_suspend_finish(unsigned long arg)
{
	struct arm_smccc_res res;

	arm_smccc_smc(PSCI_0_2_FN64_CPU_SUSPEND, arg,
		      virt_to_phys(cpu_resume), 0, 0, 0, 0, 0, &res);
	return res.a0;
}

static int meson_gx_suspend_enter(suspend_state_t state)
{
	int ret;

	if (state != PM_SUSPEND_MEM)
		return -EINVAL;
	ret = cpu_suspend(MESON_SUSPEND_PARAM, meson_gx_suspend_finish);
	if (!ret)
		meson_gx_really_slept = true;
	return ret;
}

static int meson_gx_pm_notify(struct notifier_block *nb, unsigned long action,
			      void *data)
{
	int ret;

	switch (action) {
	case PM_SUSPEND_PREPARE:
		meson_gx_really_slept = false;
		cancel_work_sync(&meson_gx_netdev_work);
		if (ir_wake_key) {
			if (!meson_gx_wake_input_ok) {
				pr_err("h96 pm: no wake input device, refusing remote standby\n");
				return notifier_from_errno(-ENODEV);
			}
			meson_gx_wake_key_buf = ir_wake_key;
			ret = scpi_send_usr_data(MESON_SCPI_CL_REMOTE,
						 &meson_gx_wake_key_buf,
						 sizeof(meson_gx_wake_key_buf));
			pr_info("h96 pm: IR wake key 0x%08x -> SCP usr data: %d\n",
				ir_wake_key, ret);
			if (ret)
				return notifier_from_errno(ret);
		}
		if (meson_gx_ao_dbg2) {
			writel(auto_wake_s, meson_gx_ao_dbg2);
			if (auto_wake_s)
				pr_info("h96 pm: BL301 timer wake armed: %u s\n",
					auto_wake_s);
		}
		break;
	case PM_POST_SUSPEND:
		if (meson_gx_ao_dbg2)
			writel(0, meson_gx_ao_dbg2);
		if (!meson_gx_really_slept)
			break;		/* aborted attempt: no wake event */
		meson_gx_really_slept = false;
		pr_info("h96 pm: resumed from deep suspend, reporting KEY_WAKEUP\n");
		if (meson_gx_wake_input_ok) {
			input_report_key(meson_gx_wake_input, KEY_WAKEUP, 1);
			input_sync(meson_gx_wake_input);
			input_report_key(meson_gx_wake_input, KEY_WAKEUP, 0);
			input_sync(meson_gx_wake_input);
		}
		schedule_work(&meson_gx_netdev_work);
		break;
	}
	return NOTIFY_DONE;
}

static struct notifier_block meson_gx_pm_nb = {
	.notifier_call = meson_gx_pm_notify,
};

static const struct platform_suspend_ops meson_gx_pm_ops = {
	.enter = meson_gx_suspend_enter,
	.valid = suspend_valid_only_mem,
};

static const struct of_device_id meson_gx_pm_match[] = {
	{ .compatible = "amlogic,meson-gx-pm", },
	{ /* sentinel */ },
};
MODULE_DEVICE_TABLE(of, meson_gx_pm_match);

static int meson_gx_pm_suspend(struct device *dev)
{
	if (meson_gx_periph_pwr)
		gpiod_set_value_cansleep(meson_gx_periph_pwr, 0);
	return 0;
}

static int meson_gx_pm_resume(struct device *dev)
{
	if (meson_gx_periph_pwr)
		gpiod_set_value_cansleep(meson_gx_periph_pwr, 1);
	return 0;
}

static const struct dev_pm_ops meson_gx_pm_dev_pm_ops = {
	.suspend = meson_gx_pm_suspend,
	.resume = meson_gx_pm_resume,
};

static int meson_gx_pm_probe(struct platform_device *pdev)
{
	int ret;

	meson_gx_periph_pwr = devm_gpiod_get_optional(&pdev->dev,
						      "peripheral-power",
						      GPIOD_OUT_HIGH);
	if (IS_ERR(meson_gx_periph_pwr)) {
		dev_warn(&pdev->dev, "h96: peripheral-power gpio unavailable (%ld)\n",
			 PTR_ERR(meson_gx_periph_pwr));
		meson_gx_periph_pwr = NULL;
	}

	ret = devm_register_sys_off_handler(&pdev->dev,
					   SYS_OFF_MODE_POWER_OFF_PREPARE,
					   SYS_OFF_PRIO_DEFAULT,
					   meson_gx_poweroff_prepare, NULL);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "h96: poweroff-prepare registration failed\n");

	meson_gx_wake_input = devm_input_allocate_device(&pdev->dev);
	if (meson_gx_wake_input) {
		meson_gx_wake_input->name = "h96-pm-wakeup";
		meson_gx_wake_input->phys = "meson-gx-pm/input0";
		input_set_capability(meson_gx_wake_input, EV_KEY, KEY_WAKEUP);
		meson_gx_wake_input_ok =
			!input_register_device(meson_gx_wake_input);
	}
	if (!meson_gx_wake_input_ok)
		dev_warn(&pdev->dev, "h96: wake input unavailable\n");

	meson_gx_ao_dbg2 = devm_ioremap(&pdev->dev, MESON_AO_DEBUG_REG2, 4);

	/*
	 * Without the notifier the IR key handover cannot happen: then do not
	 * offer suspend at all rather than risk an unwakeable sleep.
	 */
	ret = register_pm_notifier(&meson_gx_pm_nb);
	if (ret) {
		dev_err(&pdev->dev, "h96: PM notifier registration failed (%d), deep suspend disabled\n",
			ret);
		return 0;
	}

	suspend_set_ops(&meson_gx_pm_ops);
	dev_info(&pdev->dev,
		 "h96: deep suspend-to-RAM enabled (CPU_SUSPEND 0x10000), IR wake key 0x%08x%s\n",
		 ir_wake_key, meson_gx_wake_input_ok ? "" : " (no wake input!)");
	return 0;
}

static struct platform_driver meson_gx_pm_driver = {
	.probe = meson_gx_pm_probe,
	.driver = {
		.name = "meson-gx-pm",
		.of_match_table = meson_gx_pm_match,
		.pm = &meson_gx_pm_dev_pm_ops,
	},
};
module_platform_driver(meson_gx_pm_driver);
MODULE_DESCRIPTION("Amlogic Meson GX PM driver");
MODULE_LICENSE("GPL v2");
