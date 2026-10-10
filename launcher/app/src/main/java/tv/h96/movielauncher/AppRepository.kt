package tv.h96.movielauncher

import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.drawable.Drawable

/**
 * Одна плитка на экране.
 *
 * Иконка держится как Drawable: PackageManager отдаёт её из системного кэша,
 * повторная загрузка ничего не стоит, а класть в память bitmap'ы вручную —
 * лишний расход на устройстве с 2 ГиБ ОЗУ.
 */
data class AppEntry(
    val packageName: String,
    val label: String,
    val icon: Drawable,
    /** true, если приложение объявило себя как TV-приложение. */
    val isTvApp: Boolean
)

/**
 * Сбор списка приложений для сетки.
 *
 * ТЗ §33 требует брать плитки через PackageManager — так и сделано, никакой
 * своей базы и никакой сети.
 */
class AppRepository(private val pm: PackageManager) {

    fun loadLaunchableApps(): List<AppEntry> {
        // Сначала TV-приложения: у них есть интерфейс под пульт, и на
        // приставке именно они нужны в первую очередь.
        val tv = query(Intent.CATEGORY_LEANBACK_LAUNCHER)
        val tvPackages = tv.map { it.activityInfo.packageName }.toSet()

        // Затем обычные — но только те, которых ещё нет в списке TV.
        // Иначе Kodi и подобные, объявляющие обе категории, попадут дважды.
        val phone = query(Intent.CATEGORY_LAUNCHER)
            .filterNot { it.activityInfo.packageName in tvPackages }

        val entries = ArrayList<AppEntry>(tv.size + phone.size)

        tv.mapTo(entries) { toEntry(it, isTvApp = true) }
        phone.mapTo(entries) { toEntry(it, isTvApp = false) }

        // TV-приложения впереди, внутри групп — по алфавиту.
        // Сравнение без учёта регистра: иначе «Kodi» и «kodi» разъедутся.
        return entries.sortedWith(
            compareByDescending<AppEntry> { it.isTvApp }
                .thenBy { it.label.lowercase() }
        )
    }

    private fun query(category: String): List<ResolveInfo> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(category)
        return try {
            pm.queryIntentActivities(intent, 0)
        } catch (e: Exception) {
            // Пустой список лучше падения: лаунчер обязан подняться в любом
            // случае, иначе пользователь останется без домашнего экрана.
            emptyList()
        }
    }

    private fun toEntry(info: ResolveInfo, isTvApp: Boolean) = AppEntry(
        packageName = info.activityInfo.packageName,
        label = info.loadLabel(pm).toString(),
        icon = info.loadIcon(pm),
        isTvApp = isTvApp
    )
}
