package com.kerberosclaw.wherebear

import com.kerberosclaw.wherebear.location.LocationReporter
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 對應 iOS 的 isRedundantFix 單測。
 * 這條規則是純函式、不碰 Android framework，所以能在 JVM 上直接跑（./gradlew test）。
 */
class RedundantFixTest {

    private val prev = LocationReporter.Fix(lat = 25.0, lng = 121.0, atMillis = 1_000_000, accuracy = 5.0)

    @Test fun `同座標、窗內、精度沒變好 → 判定重複`() {
        assertTrue(
            LocationReporter.isRedundantFix(25.0, 121.0, 1_000_600, 5.0, prev, 2.0)
        )
    }

    @Test fun `同座標但這筆更準 → 放行（它帶了新資訊）`() {
        assertFalse(
            LocationReporter.isRedundantFix(25.0, 121.0, 1_000_600, 4.0, prev, 2.0)
        )
    }

    @Test fun `座標只要差一點就不算重複`() {
        assertFalse(
            LocationReporter.isRedundantFix(25.00001, 121.0, 1_000_600, 5.0, prev, 2.0)
        )
    }

    @Test fun `超過時間窗 → 不算重複`() {
        assertFalse(
            LocationReporter.isRedundantFix(25.0, 121.0, 1_003_000, 5.0, prev, 2.0)
        )
    }

    @Test fun `時間差取絕對值：亂序投遞同樣要擋`() {
        assertTrue(
            LocationReporter.isRedundantFix(25.0, 121.0, 999_400, 5.0, prev, 2.0)
        )
    }

    @Test fun `沒有前一筆 → 不算重複`() {
        assertFalse(
            LocationReporter.isRedundantFix(25.0, 121.0, 1_000_000, 5.0, null, 2.0)
        )
    }
}
