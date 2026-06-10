package com.ridehailing.driver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import id.flutter.flutter_background_service.BackgroundService


class BootReceiver : BroadcastReceiver() {

    companion object {
        // flutter_tool writes shared_preferences data under this prefix.
        private const val PREFS_NAME = "FlutterSharedPreferences"
        // Must match the key written by the Dart shared_preferences call.
        private const val KEY_ACTIVE_TRIP = "flutter.active_trip_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val activeTripId = prefs.getString(KEY_ACTIVE_TRIP, null) ?: return
        
        val serviceIntent = Intent(context, BackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}