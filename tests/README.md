# tests/ — 不需要模擬器的驗證

> **English summary:** Checks that run without a Simulator, a device, or a backend. Currently this holds the pure-Swift layout geometry regression for iPhone Duo: hinge divisions, camera occlusions, navigation-rail side, multi-app Split View edges, and drawer clearance are all decided by plain functions over rectangles, so they can be compiled and run straight from the repo root with `xcrun swiftc`. Passing these proves the geometry math is right; it does not prove SwiftUI renders without clipping.

## Swift 版面幾何回歸

在 macOS 用 Xcode toolchain 執行；不啟動 app、不連資料庫、不需要模擬器。

驗證一般手機與攤平直向維持抽屜、橫向收合保留清單寬度、不同尺寸與摺痕位置下的操作區避讓與背景延伸，
以及多 App Split View 的邊緣 division 不會被誤判成 App 內部的分欄。

```bash
xcrun swiftc \
  app/wherebear_app/wherebear_app/Components/AdaptiveMapLayoutGeometry.swift \
  app/wherebear_app/wherebear_app/Components/CollapsibleSheetGeometry.swift \
  tests/swift/AdaptiveMapLayoutChecks.swift \
  -o /tmp/wherebear-layout-checks
/tmp/wherebear-layout-checks
```

通過時會印出一行涵蓋範圍摘要；任何一條斷言不成立就中止並以非零離開。

幾何測試**不取代**模擬器或實機的安全區域、轉向、捲動與點擊驗收。
背景說明見 [iPhone Duo 適配筆記](../docs/IPHONE_DUO.md)與[踩坑回顧](../docs/IPHONE_DUO_LESSONS.md)。

## app 內的單元測試

需要 Xcode 測試 target 的測試（`WBClient` 的 JWT `401→refresh→retry`、CLVisit 停留 outbox 回歸）
住在 `app/wherebear_app/wherebear_appTests/`，用 dev scheme 的 Debug-Dev 設定執行。
環境選擇見[部署文件](../docs/DEPLOYMENT.md)。
