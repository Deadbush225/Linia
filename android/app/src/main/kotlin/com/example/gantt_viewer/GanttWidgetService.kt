package com.example.gantt_viewer

import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

class GanttWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return GanttWidgetFactory(applicationContext)
    }
}

private class GanttWidgetFactory(
    private val context: android.content.Context
) : RemoteViewsService.RemoteViewsFactory {

    private val tasks = mutableListOf<WidgetTask>()

    private val palette = intArrayOf(
        Color.parseColor("#7C6AF7"), Color.parseColor("#F7926A"),
        Color.parseColor("#6BBFF7"), Color.parseColor("#F7C86A"),
        Color.parseColor("#6AF79E"), Color.parseColor("#F76A9E"),
        Color.parseColor("#6AF7F0"), Color.parseColor("#C86AF7"),
        Color.parseColor("#F7F06A"), Color.parseColor("#6A9EF7")
    )

    override fun onCreate() {
        loadTasks()
    }

    override fun onDataSetChanged() {
        loadTasks()
    }

    override fun onDestroy() {
        tasks.clear()
    }

    override fun getCount(): Int = tasks.size

    override fun getViewAt(position: Int): RemoteViews {
        if (position !in tasks.indices) {
            return RemoteViews(context.packageName, R.layout.gantt_widget_item)
        }

        val item = tasks[position]
        val views = RemoteViews(context.packageName, R.layout.gantt_widget_item)
        val color = palette[item.colorIdx % palette.size]

        views.setTextViewText(R.id.task_title, item.title)
        views.setInt(R.id.task_dot, "setColorFilter", color)

        val dueText = formatDue(item.endDate)
        views.setTextViewText(R.id.task_due, dueText)
        if (dueText.isEmpty()) {
            views.setTextColor(R.id.task_due, Color.parseColor("#AAAAAA"))
        } else {
            val daysLeft = daysUntilDue(item.endDate)
            views.setTextColor(
                R.id.task_due,
                when {
                    daysLeft < 0 -> Color.parseColor("#E84040")
                    daysLeft == 0 -> Color.parseColor("#FFCD5E")
                    daysLeft <= 3 -> Color.parseColor("#F7926A")
                    else -> Color.parseColor("#AAAAAA")
                }
            )
        }
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long = position.toLong()

    override fun hasStableIds(): Boolean = true

    private fun loadTasks() {
        tasks.clear()
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", android.content.Context.MODE_PRIVATE)
        val json = prefs.getString("tasks_json", "[]") ?: "[]"
        val arr = try {
            JSONArray(json)
        } catch (_: Exception) {
            JSONArray()
        }

        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val rawEndDate = o.optString("endDate", "")
            val endDate = if (isValidDate(rawEndDate)) rawEndDate else ""
            tasks.add(
                WidgetTask(
                    title = o.optString("title", "Untitled"),
                    endDate = endDate,
                    colorIdx = o.optInt("colorIdx", i)
                )
            )
        }
    }

    private fun isValidDate(value: String): Boolean {
        if (value.isBlank() || value == "null") return false
        return Regex("\\d{4}-\\d{2}-\\d{2}").matches(value)
    }

    private fun formatDue(endDate: String): String {
        if (endDate.isEmpty()) return ""
        val daysLeft = daysUntilDue(endDate)
        return when {
            daysLeft < 0 -> "Overdue ${-daysLeft}d"
            daysLeft == 0 -> "Due today"
            daysLeft <= 3 -> "Due in ${daysLeft}d"
            else -> endDate
        }
    }

    private fun daysUntilDue(endDate: String): Int {
        return try {
            val parts = endDate.split("-")
            val cal = java.util.Calendar.getInstance().apply {
                set(parts[0].toInt(), parts[1].toInt() - 1, parts[2].toInt(), 0, 0, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }
            val today = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0)
                set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0)
                set(java.util.Calendar.MILLISECOND, 0)
            }
            ((cal.timeInMillis - today.timeInMillis) / 86400000L).toInt()
        } catch (_: Exception) {
            9999
        }
    }
}

private data class WidgetTask(
    val title: String,
    val endDate: String,
    val colorIdx: Int
)
