package com.example.dev_vpn

import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.os.Bundle
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity: FlutterActivity() {

    private val CHANNEL = "apps.channel"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->

                val pm = packageManager

                when (call.method) {

                    "getInstalledApps" -> {
                        try {
                            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)

                            val list = apps
                                .filter { pm.getLaunchIntentForPackage(it.packageName) != null }
                                .map {
                                    mapOf(
                                        "packageName" to it.packageName,
                                        "appName" to pm.getApplicationLabel(it).toString()
                                    )
                                }

                            result.success(list)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }

                    "getAppIcon" -> {
                        val packageName = call.argument<String>("packageName")

                        if (packageName == null) {
                            result.success(null)
                            return@setMethodCallHandler
                        }

                        try {
                            val drawable = pm.getApplicationIcon(packageName)

                            val bitmap = if (drawable is BitmapDrawable) {
                                drawable.bitmap
                            } else {
                                val bmp = Bitmap.createBitmap(
                                    drawable.intrinsicWidth,
                                    drawable.intrinsicHeight,
                                    Bitmap.Config.ARGB_8888
                                )
                                val canvas = Canvas(bmp)
                                drawable.setBounds(0, 0, canvas.width, canvas.height)
                                drawable.draw(canvas)
                                bmp
                            }

                            val stream = ByteArrayOutputStream()
                            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)

                            result.success(stream.toByteArray())

                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
