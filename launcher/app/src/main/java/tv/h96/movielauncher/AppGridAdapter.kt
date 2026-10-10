package tv.h96.movielauncher

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView

/**
 * Адаптер сетки плиток.
 *
 * Фокус — главное здесь: устройством управляют пультом, поэтому каждая
 * плитка обязана быть фокусируемой и заметно реагировать на фокус.
 * Без этого по сетке невозможно передвигаться.
 */
class AppGridAdapter(
    private val onClick: (AppEntry) -> Unit,
    private val onLongClick: (AppEntry) -> Unit
) : RecyclerView.Adapter<AppGridAdapter.Holder>() {

    private var items: List<AppEntry> = emptyList()

    fun submit(newItems: List<AppEntry>) {
        // DiffUtil вместо notifyDataSetChanged: последний сбрасывает фокус,
        // и пульт «теряет» текущую плитку — на телевизоре это очень заметно.
        val diff = DiffUtil.calculateDiff(object : DiffUtil.Callback() {
            override fun getOldListSize() = items.size
            override fun getNewListSize() = newItems.size

            override fun areItemsTheSame(oldPos: Int, newPos: Int) =
                items[oldPos].packageName == newItems[newPos].packageName

            override fun areContentsTheSame(oldPos: Int, newPos: Int) =
                items[oldPos].label == newItems[newPos].label
        })
        items = newItems
        diff.dispatchUpdatesTo(this)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Holder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_app, parent, false)
        return Holder(view)
    }

    override fun onBindViewHolder(holder: Holder, position: Int) {
        holder.bind(items[position])
    }

    override fun getItemCount() = items.size

    inner class Holder(view: View) : RecyclerView.ViewHolder(view) {
        private val icon: ImageView = view.findViewById(R.id.app_icon)
        private val label: TextView = view.findViewById(R.id.app_label)

        fun bind(app: AppEntry) {
            icon.setImageDrawable(app.icon)
            label.text = app.label

            itemView.isFocusable = true
            itemView.isFocusableInTouchMode = true

            // Подсветка фокуса — не украшение, а единственный способ понять,
            // где ты находишься, когда управляешь пультом с дивана.
            itemView.setOnFocusChangeListener { v, hasFocus ->
                val scale = if (hasFocus) 1.15f else 1.0f
                v.animate()
                    .scaleX(scale)
                    .scaleY(scale)
                    // Коротко: анимация не должна ощущаться как задержка
                    // при быстром перемещении по сетке (ТЗ §33).
                    .setDuration(120)
                    .start()
                v.elevation = if (hasFocus) 16f else 0f
                label.isSelected = hasFocus   // включает бегущую строку
            }

            itemView.setOnClickListener { onClick(app) }
            itemView.setOnLongClickListener {
                onLongClick(app)
                true
            }
        }
    }
}
