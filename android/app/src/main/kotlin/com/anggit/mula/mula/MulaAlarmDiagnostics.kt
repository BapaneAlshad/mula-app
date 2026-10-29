package com.anggit.mula.mula

import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Reads Android's actual grants. Opening settings never implies a grant. */
class MulaAlarmDiagnostics(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method !in setOf("alarmDiagnostics", "openAlarmSettings", "openNotificationSettings", "openBatterySettings")) return false
        try {
            when (call.method) {
                "alarmDiagnostics" -> {
                    val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    val alarms = activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                    val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                    val testChannelAllowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        manager.getNotificationChannel("mula_alarm_test")?.importance != NotificationManager.IMPORTANCE_NONE
                    } else true
                    result.success(mapOf(
                        "notificationsAllowed" to manager.areNotificationsEnabled(),
                        "exactAlarmsAllowed" to (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()),
                        "batteryUnrestricted" to power.isIgnoringBatteryOptimizations(activity.packageName),
                        "testChannelAllowed" to testChannelAllowed,
                        "doNotDisturb" to (manager.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL),
                        "androidVersion" to Build.VERSION.RELEASE,
                        "device" to "${Build.MANUFACTURER} ${Build.MODEL}"
                    ))
                }
                "openAlarmSettings" -> open(result, if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${activity.packageName}"))
                } else appDetails())
                "openNotificationSettings" -> open(result, if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                } else appDetails())
                "openBatterySettings" -> open(result, Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        } catch (error: Exception) {
            result.error("ALARM_DIAGNOSTICS", error.message ?: "Pengaturan Android tidak tersedia.", null)
        }
        return true
    }

    private fun appDetails() = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.parse("package:${activity.packageName}"))

    private fun open(result: MethodChannel.Result, intent: Intent) {
        val target = if (intent.resolveActivity(activity.packageManager) != null) intent else appDetails()
        activity.startActivity(target)
        result.success(null)
    }
}
