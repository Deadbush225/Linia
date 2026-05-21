package com.deadbush225.linia

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class GanttWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        scheduleAutoRefresh(context)
        val tasks = scanAndBuildTaskJson(context)
        for (id in appWidgetIds) {
            renderWidget(context, appWidgetManager, id, tasks)
        }
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        scheduleAutoRefresh(context)
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        cancelAutoRefresh(context)
    }

    // Called by AlarmManager every 30 minutes
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, GanttWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val tasks = scanAndBuildTaskJson(context)
                for (id in ids) renderWidget(context, manager, id, tasks)
            }
        }
    }

    companion object {
        private const val ACTION_REFRESH = "com.deadbush225.linia.WIDGET_REFRESH"
        // Refresh every 30 minutes (minimum meaningful interval)
        private const val REFRESH_INTERVAL_MS = 30 * 60 * 1000L

        private val PALETTE = intArrayOf(
            Color.parseColor("#7C6AF7"), Color.parseColor("#F7926A"),
            Color.parseColor("#6BBFF7"), Color.parseColor("#F7C86A"),
            Color.parseColor("#6AF79E"), Color.parseColor("#F76A9E"),
            Color.parseColor("#6AF7F0"), Color.parseColor("#C86AF7"),
            Color.parseColor("#F7F06A"), Color.parseColor("#6A9EF7")
        )

        // ── AlarmManager scheduling ───────────────────────────────────────────

        private fun refreshIntent(context: Context): PendingIntent {
            val intent = Intent(context, GanttWidgetProvider::class.java).apply {
                action = ACTION_REFRESH
            }
            return PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        fun scheduleAutoRefresh(context: Context) {
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarm.setInexactRepeating(
                AlarmManager.RTC,
                System.currentTimeMillis() + REFRESH_INTERVAL_MS,
                REFRESH_INTERVAL_MS,
                refreshIntent(context)
            )
        }

        fun cancelAutoRefresh(context: Context) {
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarm.cancel(refreshIntent(context))
        }

        // ── Markdown scanner (runs in widget process, no Flutter needed) ──────

        /** Reads project root from shared_preferences */
        private fun getProjectRoot(context: Context): String? {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val active = prefs.getString("flutter.active_project_root", null)
            if (!active.isNullOrBlank()) return active

            val roots = prefs.getStringSet("flutter.project_roots", null)
            if (!roots.isNullOrEmpty()) return roots.first()

            return prefs.getString("flutter.project_root", null)
        }

        private fun parseField(frontmatter: String, vararg keys: String): String? {
            for (key in keys) {
                val regex = Regex("""^$key\s*:\s*(.+)$""", RegexOption.MULTILINE)
                val v = regex.find(frontmatter)?.groupValues?.get(1)?.trim()
                    ?.trimStart('"', '\'')?.trimEnd('"', '\'')
                if (!v.isNullOrEmpty()) return v
            }
            return null
        }

        private fun daysUntilDue(endDate: String): Int {
            return try {
                val parts = endDate.split("-")
                val cal = java.util.Calendar.getInstance().apply {
                    set(parts[0].toInt(), parts[1].toInt() - 1, parts[2].toInt(), 0, 0, 0)
                    set(java.util.Calendar.MILLISECOND, 0)
                }
                val today = java.util.Calendar.getInstance().apply {
                    set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
                }
                ((cal.timeInMillis - today.timeInMillis) / 86400000L).toInt()
            } catch (e: Exception) { 9999 }
        }

        data class TaskEntry(
            val title: String, val endDate: String?,
            val status: String, val colorIdx: Int
        )

        private fun parseMdFile(file: File, colorIdx: Int): TaskEntry? {
            return try {
                val text = file.readText()
                val fmMatch = Regex("""^---\r?\n([\s\S]*?)\r?\n---""", RegexOption.MULTILINE).find(text)
                    ?: return null
                val fm = fmMatch.groupValues[1]
                val title = parseField(fm, "title") ?: file.nameWithoutExtension
                val status = parseField(fm, "status") ?: "todo"
                val endDate = parseField(fm, "endDate", "end_date", "due", "end")
                TaskEntry(title, endDate, status, colorIdx)
            } catch (e: Exception) { null }
        }

        private fun scanTasks(rootPath: String): List<TaskEntry> {
            val root = File(rootPath)
            if (!root.exists()) return emptyList()
            val tasks = mutableListOf<TaskEntry>()
            var colorIdx = 0

            fun scanDir(dir: File) {
                dir.listFiles()?.filter { it.isFile && it.extension == "md" }?.forEach { f ->
                    parseMdFile(f, colorIdx)?.let { tasks.add(it); colorIdx++ }
                }
            }

            scanDir(root)
            root.listFiles()?.filter { it.isDirectory && it.name != "archive" }?.forEach { scanDir(it) }
            tasks.sortWith(compareBy { it.endDate?.let { d -> daysUntilDue(d) } ?: 9999 })
            return tasks
        }

        fun scanAndBuildTaskJson(context: Context): JSONArray {
            val root = getProjectRoot(context) ?: return JSONArray()
            val tasks = scanTasks(root)
            val arr = JSONArray()
            tasks.forEachIndexed { i, t ->
                arr.put(JSONObject().apply {
                    put("title", t.title)
                    put("endDate", t.endDate ?: "")
                    put("status", t.status)
                    put("colorIdx", t.colorIdx)
                })
            }
            // Also persist so the Flutter app stays in sync when opened
            context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
                .edit().putString("tasks_json", arr.toString()).commit()
            return arr
        }

        // ── Widget rendering ──────────────────────────────────────────────────

        fun updateWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
            val tasks = scanAndBuildTaskJson(context)
            renderWidget(context, appWidgetManager, appWidgetId, tasks)
        }

        fun renderWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int, tasks: JSONArray) {
            val views = RemoteViews(context.packageName, R.layout.gantt_widget)

            // Tap widget → open the app
            val launchIntent = Intent(context, MainActivity::class.java)
            val pi = PendingIntent.getActivity(
                context, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pi)

            val svcIntent = Intent(context, GanttWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            views.setRemoteAdapter(R.id.task_list, svcIntent)
            views.setEmptyView(R.id.task_list, R.id.widget_empty)
            views.setTextViewText(R.id.widget_title, "📋 Tasks (${tasks.length()})")

            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.task_list)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
