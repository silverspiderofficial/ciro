package com.silverspider.kiro.device

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs
import java.io.File

/** Hardware facts used by the first-run check to recommend a model. */
object DeviceInfoProvider {

    fun collect(context: Context): Map<String, Any?> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val cores = Runtime.getRuntime().availableProcessors()
        val maxFreqs = (0 until cores).map { readLong("/sys/devices/system/cpu/cpu$it/cpufreq/cpuinfo_max_freq") }
        val topFreq = maxFreqs.maxOrNull() ?: 0L
        // "Performance" cores: within 80% of the fastest core's max frequency.
        val bigCores = if (topFreq > 0) maxFreqs.count { it >= topFreq * 0.8 } else cores / 2
        val features = cpuFeatures()
        val stat = StatFs(context.filesDir.path)
        val soc: String
        val socMaker: String
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            soc = Build.SOC_MODEL
            socMaker = Build.SOC_MANUFACTURER
        } else {
            soc = Build.HARDWARE
            socMaker = ""
        }
        return mapOf(
            "totalRam" to mem.totalMem,
            "availRam" to mem.availMem,
            "lowMemory" to mem.lowMemory,
            "lowMemoryThreshold" to mem.threshold,
            "largeHeapMb" to am.largeMemoryClass,
            "cores" to cores,
            "bigCores" to bigCores.coerceAtLeast(1),
            "maxFreqMhz" to (topFreq / 1000L),
            "soc" to soc,
            "socManufacturer" to socMaker,
            "hardware" to Build.HARDWARE,
            "board" to Build.BOARD,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "sdkInt" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "dotprod" to features.contains("asimddp"),
            "i8mm" to features.contains("i8mm"),
            "fp16" to features.contains("asimdhp"),
            "freeStorage" to stat.availableBytes,
        )
    }

    private fun readLong(path: String): Long = try {
        File(path).readText().trim().toLong()
    } catch (e: Exception) {
        0L
    }

    private fun cpuFeatures(): Set<String> = try {
        File("/proc/cpuinfo").useLines { lines ->
            lines.firstOrNull { it.startsWith("Features") }
                ?.substringAfter(':')
                ?.trim()
                ?.split(Regex("\\s+"))
                ?.toSet()
                ?: emptySet()
        }
    } catch (e: Exception) {
        emptySet()
    }
}
