package tv.h96.movielauncher

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView

/**
 * Главный экран: сетка плиток приложений.
 *
 * Требования ТЗ §33 и §34, которые определили устройство этого класса:
 *   - быстрый старт: никаких тяжёлых фреймворков, сеть не трогаем;
 *   - обои локальные;
 *   - плитки берутся из PackageManager;
 *   - навигация D-pad'ом.
 *
 * Отсюда обычный RecyclerView с GridLayoutManager вместо Leanback: нужна
 * ровно сетка с фокусом, а библиотека тянет заметно больше.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var grid: RecyclerView
    private lateinit var adapter: AppGridAdapter

    /** Число колонок. Для 1080p при плитке ~200 dp получается шесть. */
    private val columns = 6

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        grid = findViewById(R.id.app_grid)
        grid.layoutManager = GridLayoutManager(this, columns)

        // Размер плиток фиксирован, поэтому RecyclerView может не пересчитывать
        // геометрию при каждом изменении данных — заметно для отзывчивости.
        grid.setHasFixedSize(true)

        // Кэш побольше: при прокрутке пультом плитки уходят и возвращаются
        // часто, а пересоздание ViewHolder'а с иконкой стоит дороже памяти.
        grid.setItemViewCacheSize(columns * 3)

        adapter = AppGridAdapter(
            onClick = { app -> launchApp(app) },
            onLongClick = { app -> openAppInfo(app) }
        )
        grid.adapter = adapter

        loadApps()
    }

    override fun onResume() {
        super.onResume()
        // Список мог измениться, пока лаунчер был в фоне: что-то поставили
        // или удалили. Перечитываем — это дешевле, чем держать BroadcastReceiver.
        loadApps()
    }

    private fun loadApps() {
        // PackageManager отдаёт данные быстро и из уже загруженного системой
        // кэша, поэтому отдельный поток здесь только добавил бы мигание.
        // Если на устройстве окажется сотня приложений и это станет заметно —
        // выносить в корутину, замерив предварительно.
        val apps = AppRepository(packageManager).loadLaunchableApps()
        adapter.submit(apps)

        // Фокус на первой плитке: без него пульт «не знает», откуда начинать.
        grid.post { grid.findViewHolderForAdapterPosition(0)?.itemView?.requestFocus() }
    }

    private fun launchApp(app: AppEntry) {
        val intent = packageManager.getLaunchIntentForPackage(app.packageName)
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun openAppInfo(app: AppEntry) {
        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        intent.data = android.net.Uri.parse("package:${app.packageName}")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /**
     * Лаунчер — это HOME, поэтому «назад» здесь никуда не ведёт: выходить
     * некуда. Перехватываем, чтобы случайное нажатие не показывало пустой
     * экран и не давало системе закрыть активность.
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        return when (keyCode) {
            KeyEvent.KEYCODE_BACK -> true
            else -> super.onKeyDown(keyCode, event)
        }
    }
}
