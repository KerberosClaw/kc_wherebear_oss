package com.kerberosclaw.wherebear.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException

/**
 * 時間慣例（契約 §4）：RFC3339 offset-aware。
 * 對應 iOS 的 WBDate + RelativeTime.swift。
 */
object WBTime {
    val zone: ZoneId get() = runCatching { ZoneId.of(Config.TZ) }.getOrElse { ZoneId.systemDefault() }

    /** 解析含 / 不含小數秒的 ISO8601 */
    fun parse(s: String?): Instant? {
        if (s.isNullOrBlank()) return null
        return try {
            ZonedDateTime.parse(s, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
        } catch (e: DateTimeParseException) {
            // PostgREST 偶爾回不帶 offset 的 timestamp → 當作 UTC（契約要求 offset-aware，這是防禦）
            runCatching { Instant.parse(s + "Z") }.getOrNull()
                ?: runCatching { Instant.parse(s) }.getOrNull()
        }
    }

    /** 帶小數秒（對應 iOS .withFractionalSeconds），用於 location_history 的 captured_at */
    fun isoMillis(instant: Instant): String =
        DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(
            instant.atZone(ZoneId.of("UTC")).withNano((instant.nano / 1_000_000) * 1_000_000)
        )

    /** 不帶小數秒，用於 visits 的 arrived_at / departed_at（去重鍵，秒級即可） */
    fun isoSeconds(instant: Instant): String =
        DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(instant.atZone(ZoneId.of("UTC")).withNano(0))

    fun today(): LocalDate = LocalDate.now(zone)

    fun dayString(date: LocalDate): String = date.toString() // yyyy-MM-dd

    /** 某本地日的 [start, end) 邊界（跨午夜歸日以使用者時區算） */
    fun dayBounds(date: LocalDate): Pair<Instant, Instant> =
        date.atStartOfDay(zone).toInstant() to date.plusDays(1).atStartOfDay(zone).toInstant()

    fun hhmm(instant: Instant): String =
        DateTimeFormatter.ofPattern("HH:mm").format(instant.atZone(zone))

    fun mdShort(instant: Instant): String =
        DateTimeFormatter.ofPattern("M/d").format(instant.atZone(zone))
}

/** 對應 iOS relativeZh() */
fun relativeZh(instant: Instant, now: Instant = Instant.now()): String {
    val s = now.epochSecond - instant.epochSecond
    return when {
        s < 60 -> "剛剛"
        s < 3600 -> "${s / 60} 分鐘前"
        s < 86400 -> "${s / 3600} 小時前"
        s < 86400 * 30 -> "${s / 86400} 天前"
        else -> DateTimeFormatter.ofPattern("yyyy/MM/dd").format(instant.atZone(WBTime.zone))
    }
}
