# iPhone Duo 版面適配：踩坑與修法

> **English summary:** The things that actually went wrong while adapting wherebear's SwiftUI layout to iPhone Duo, and how each was fixed. Nine write-ups, each with the symptom, the wrong assumption behind it, and the change: rotation moves the camera and the system rail to the other side; "where the background may paint" is not "where the user may tap"; moving a drawer does not shrink its scroll view; a side rail needs no bottom inset; a date card must fit before it can be centred; a photo-import sheet cannot keep one fixed height; toolbar contrast must be judged on a real map; an unsupported orientation is a plist problem, not a layout one; and — the big one — the window edge between two side-by-side apps is not an in-app fold. Ends with what the tests do and do not prove, plus the regression checklist for the next person. **Nothing here was confirmed on physical hardware — see [the hardware caveat in the layout notes](IPHONE_DUO.md).**

> 本文整理整輪適配的經驗；目前版面規格與早期討論見 [適配筆記](IPHONE_DUO.md)。

這次容易漏掉兩件事：旋轉會改變鏡頭、系統導覽列與可用空間；多 App 共用內螢幕時，同一條摺線對單一 App 的意義也會不同。只確認正常直向、其中一個橫向或單一 App 滿版，仍會留下其他情境才出現的重疊。

## 1. 同樣是橫向，鏡頭和導覽列可以在另一邊

**症狀：**闔上橫放時，一個方向的位置卡掉到左下，跟回報、定位按鈕疊在一起；另一個方向則連系統導覽列也移到左邊，所有按鈕擠成一團。時間軸的日期操作列也會被抽屜蓋住。

**原因：**舊計算直接從鏡頭中心的 Y 座標推導頂部間距，等於假設鏡頭永遠在上面。鏡頭轉到下角後，「上方操作列」就跟著往下跑；首頁操作鍵固定靠左，也沒有考慮系統導覽列會換邊。

**修法：**

- 以目前視窗的 `toolbarVerticalEdge` 讀取導覽列所在側，不快取裝置方向。
- 闔上模式的頂部間距限制在上方範圍；下方鏡頭不參與上方操作列的定位。
- 闔上首頁的回報、定位控制組放在導覽列另一側。
- 相機保留區暫時缺席時，仍可用側邊導覽列維持窄視窗配置，避免切換瞬間換錯版面。後續 Split View 實測確認，這種配置也會出現在內螢幕，不能據此判定實體螢幕已闔上。
- 這組修正作用於窄視窗浮層模式；單一 App 寬版的地圖、清單分區與已確認的控制組位置保留。

**之後怎麼查：**橫向必須測左右兩邊，不能只測寬高交換。幾何測試另外涵蓋鏡頭四角、左右導覽列與暫時沒有鏡頭保留區的情況。

## 2. 背景要填滿，互動內容卻必須避開摺痕

**症狀：**半開時，背景在摺痕旁露出空隙；另一種修法若把整塊內容直接放大，又會讓按鈕或清單進入摺痕保留區。展開直向也曾因頂部留白過多，與右側系統圖示失去對齊。

**原因：**把「背景可以畫到哪裡」和「使用者可以點到哪裡」當成同一個矩形；或在已經採用安全內容座標的地方，再加一次整條安全區間距。

**修法：**

- `AdaptiveMapLayout` 統一使用安全內容區的本地座標，分別提供地圖、清單與地圖背景範圍。
- 分區採用系統目前啟用的 `reservedRegions`。division 的 `frame` 已包含 margins，不能再加一次；後續修正詳見第 9 節。不用螢幕正中央常數猜摺痕。
- 背景可以延伸到摺痕中央；直接互動的地圖與清單仍避開完整保留區，摺痕區另有手勢遮擋。
- 書本式維持左清單、右地圖；筆電式維持上地圖、下清單。日期遮罩與匯入面板跟著清單分區走。

## 3. 抽屜移下去，不代表捲動視窗也變矮

**症狀：**清單最後幾筆捲不到真正可見的位置；闔上橫向時，把抽屜拉到最開又會撞上日期、熊掌、相機按鈕。

這裡其實有兩個問題：

| 問題 | 原因 | 修法 |
|---|---|---|
| 抽屜尾端被切掉 | 只用 `offset` 移動整塊抽屜，`ScrollView` 仍以原本的大高度計算可見範圍 | 抽屜 frame 使用實際可見高度，再保留必要的尾端間距 |
| 全開撞到操作列 | 全開位置只用視窗高度的固定比例，沒有量測上方內容 | 闔上模式量測操作列與選取卡的實際高度，抽屜頂端至少再讓出 12 點 |

例如高度 390 點的測試視窗，舊全開位置是 `390 × 0.15 = 58.5`；若工具列到 Y=70，必然重疊。修正後最低位置是 `70 + 12 = 82`。

三段位置由 `CollapsibleSheetStops` 統一限制，保持全開、半開、收合依序排列；空間不足時可以重合，不能互相倒置。視窗尺寸改變時也清掉未結束的拖曳位移，避免旋轉後沿用舊尺寸的偏移。

## 4. 導覽列在側邊，就不需要替它預留底部高度

**症狀：**設定頁內容正常，但捲到底後，版本號下面多出一大片空白。

**原因：**原本替底部分頁列保留的 100 點 padding，在系統改成側邊導覽列後仍然套用。

**修法：**側邊導覽列模式取消這筆額外留白，保留一般內容邊距；底部分頁列模式維持原本的預留。時間軸也依抽屜／分欄容器分別處理尾端間距。

這類問題要看「捲到底」的畫面，初始畫面通常看不出來。

## 5. 日期卡片置中之前，要先確保內容放得下

**症狀：**時間區間與多選日曆靠在左上；直接改成置中仍不夠，橫向時日曆底部的取消、完成按鈕會被切掉。

**原因：**直向日曆的內容高度超過短視窗；只有改對齊方式，並不會產生足夠的空間。分欄時如果用整個螢幕置中，還會把卡片搬進地圖或跨過摺痕。

**修法：**時間區間與多選日曆共用 `AdaptiveDateDialog`：

- 在傳入的可用區域置中；分欄時，這個區域是清單分區。
- 內容放得下就使用自然高度，不把卡片撐滿整個畫面。
- 短而寬的區域改成左日曆、右操作區；直向維持上下排列。
- 放不下時只捲動內容，取消／完成留在捲動區外。
- 以六週月份驗證高度；只測五週月份，容易漏掉最後一列溢出。

**另一個坑：**時間區間原先使用 compact `DatePicker`，點日期會再跳一層系統日曆。它的位置跟著按鈕和可用空間變動，可能蓋住原卡片與完成按鈕；只搬動外層卡片無法消除這種遮擋。

最後改成**同一張卡片內切換「從／到」，下方直接選日期**。沿用 `BearCalendar`，以可選的日期回呼支援區間端點；既有多選行為、日期套用與區間上限保留。這次整合的是時間軸時間區間，並未全面替換相簿匯入內的自訂日期欄位。

## 6. 相簿匯入不能永遠固定一個 sheet 高度

**症狀：**直向相簿匯入的內容只占上半部，取消按鈕下方留白很大。

**原因：**原生 sheet 固定使用 620 點高度，但預設時間範圍、展開自訂日期、掃描結果與匯入訊息的內容高度不同。

**修法：**量測實際內容高度，更新 sheet 的高度，保留最小高度與捲動能力。分欄內嵌匯入仍使用清單分區；筆電式寬版採左右內容配置，避免把手機直向表單直接拉長。

## 7. 工具列的分組和對比，要放在真實地圖上看

**症狀：**熊掌獨自浮在地圖角落，與日期操作分離；改成框景圖示後，使用者看不出用途。頭貼獨占第一排，造成左上大塊留白。半透明按鈕則與道路、地圖標記混在一起。

**修法：**

- 框景操作保留熊掌圖示，語意為「顯示全部足跡」，與日期及相機集中成操作列。
- 寬度足夠時把帳號與日期等控制放在同列；窄側欄採明確的兩排配置，避免只有頭貼占一整排。
- 熊掌與相機使用不透明深色底，保持與地圖的對比；首頁回報熊掌則保留自己的狀態文字。

深色模式裡看起來漂亮的玻璃材質，疊在高細節地圖上未必清楚。要用有道路、地名與足跡標記的畫面檢查，不能只看空白底預覽。

## 8. 倒過來不旋轉，先查方向宣告

**症狀：**從橫向轉成倒置直向，裝置外框轉了，app 仍停在橫向。

**原因：**iPhone 的支援方向沒有包含 `UIInterfaceOrientationPortraitUpsideDown`，不是單純排版沒有更新。

**修法：**補齊 iPhone 四個方向，並檢查建置產物的 `Info.plist`。本輪最後採用支援旋轉的配置；早期「把外螢幕鎖成直向」的提案沒有實作，多視窗也保持啟用。

只看來源 plist 或成功編譯還不夠；建置設定可能影響最終宣告，安裝的 app 也必須確實是新產物。

## 9. 多 App 的視窗邊緣，不等於 App 內部的分欄線

**症狀：**單一 App 使用內螢幕正常；與另一個 App 左右分割時，攤平正常，一折就跑版。時間軸兩邊都誤切成「左列表、右地圖」：App 在左邊時地圖被擠掉，在右邊時列表被擠掉。首頁的頭貼、控制組位置也跟著切換，左側視窗還有不協調的留白。

**實測證據：**分別擷取首頁與時間軸在左／右位置、攤平／折疊的資料。App 視窗維持 469 × 669 點，傳入版面計算的安全內容維持 385 × 635 點，size class 也沒變。改變的是邊緣 division 從 inactive 變成 active。UIKit 根視窗與 SwiftUI 內容的安全區也不一定相同，不能把根視窗座標直接當成內容座標。

**真正的錯誤：**舊程式只要看到 division 與 App 相交，就當成「App 內部有左右兩頁」。這個前提在單一 App 書本式成立，在多 App 分割卻不成立。以下是版面示意，不是裝置姿態判斷規則：

```text
單一 App 佔整片內螢幕：
+---------------------------------+
|       WhereBear                 |
|  列表          |  地圖          |
+----------------|----------------+
                 ^ 摺線穿過 App 內部，兩側都有空間

兩個 App 共用內螢幕：
+----------------+----------------+
|  WhereBear     |  另一個 App    |
|  地圖＋抽屜    |                |
+----------------+----------------+
                 ^ 對 WhereBear 而言，這裡是邊緣

舊程式仍然硬切 WhereBear 自己：
放左邊： [       列表       ][地圖寬 0]
放右邊： [列表寬 0][       地圖       ]
```

另外還有一個放大問題：API 的 `frame` 本來已含互動邊距，舊 adapter 又把左右 margins 各加 20 點。實測 13.5 點的保留區因此被當成 53.5 點。以下皆為 SwiftUI 安全內容的本地座標：

| App 位置 | 正確 division 的 X 範圍 | 舊程式再次擴張後 | 舊分欄結果 |
|---|---|---|---|
| 右側 | 0～13.5 | -20～33.5 | 列表 0，地圖 351.5 點 |
| 左側 | 371.5～385 | 351.5～405 | 列表 351.5，地圖 0 點 |

只移除重複 margins 仍不夠：邊緣還是邊緣，舊分欄判斷仍會算出其中一欄寬度為零。必須一起修正「什麼時候可以分欄」。目前證據指向 App 對系統幾何的解讀錯誤，不能據此宣稱是作業系統的 Split View bug。

**修法：**

- 直接使用目前 View 的 reserved-region frame，不額外加 margins，也不用整個螢幕尺寸或鉸鏈角度代替 App 可用區域。
- 只有保留區橫跨內容，而且兩側各至少有 120 點，才啟用書本／筆電式分欄。120 點是本 App 防止極小分區的門檻，不是 Apple 規定。
- 邊緣與細條區域只讓前景控制、抽屜、日期卡片避讓，地圖背景保留原本範圍；不把整個 App 再切一刀。
- 將 `closed` 改名為 `compactOverlay`，明確表示窄視窗版面，避免把內螢幕的 Split View 當成實體闔上。左右窄視窗折疊前後都保留同一種抽屜與控制組。
- 左側視窗的資訊、時間軸工具列與首頁控制靠右，右側視窗靠左；仍保留系統側欄安全區。
- 只有版面模式或地圖背景範圍改變才重新框景；邊緣保留區啟用／停用不應搶走使用者的縮放。抽屜段位、日期與停留點選取、捲動狀態不因這種折疊切換而重設。

**測試漏在哪裡：**原有 378 組測試把摺線放在 App 內部，全部通過仍無法抓到「摺線只碰到邊緣」。這次先把實際左右輸入加入測試，確認舊版失敗，再修到通過；另補微小側欄、超出視窗、部分相交、折疊前後框景判斷，以及日期卡片的窄視窗尺寸。

**之後怎麼查：**「內螢幕單一 App」和「內螢幕多 App」要分開測，多 App 再分左右位置，各跑展開→折疊→展開。記錄目前 View 的尺寸、safe area、size class、reserved region frame／active、導覽列側邊與最後選出的版面模式，才能分清楚是系統改了輸入，還是 App 解讀錯誤。

## 驗證留下了什麼

🔴 **全部證據都來自 Simulator 與單元層級的檢查，沒有任何一項在實體 iPhone Duo 上跑過。**
完整的實機待驗清單見[適配筆記](IPHONE_DUO.md)開頭的「尚未在實機上驗證過」。

| 證據 | 本輪結果與範圍 |
|---|---|
| 純 Swift 幾何檢查 | 通過。保留 378 組摺痕配置，增加鏡頭四角、導覽列換邊、鏡頭暫時缺席、展開分區不變，117 組抽屜高度／標頭組合，以及左右 Split View 的實測、邊緣／細條／超出視窗與框景判斷案例 |
| SwiftUI hosting 測試 | 通過。1 個測試方法內跑 12 種配置：區間／多選 × 6 種可用尺寸（含 Split View 折疊前後），以六週月份檢查操作鈕可見性，並檢查高直向卡片置中；保存 12 張渲染附件 |
| Debug-Dev 建置與安裝 | 已完成，使用 dev 設定建置並安裝到 Duo Simulator；未部署正式環境 |
| Simulator 操作驗收 | 單一 App 各姿態與多 App Split View 左右位置的展開→折疊→展開均已逐項操作確認 |

幾何測試通過，不能證明 SwiftUI 實際渲染不會裁切；hosting 測試使用共用容器與測試控制項，也不能代替完整日期操作、相簿匯入和姿態切換。一般手機與多視窗的完整互動回歸不在這次自動測試證據內。

下次再動這裡，至少按下面的順序檢查；這是回歸清單，不代表本輪已逐格完成所有組合：

1. 闔上直向、左右橫向、倒置直向；兩個橫向都確認導覽列與操作鍵的位置。
2. 攤平直／橫、半開書本式、半開筆電式，再做闔上 → 展開 → 闔上。
3. 時間軸抽屜全開時旋轉，包含有選取停留點、長地名與清單捲到底。
4. 在日期卡片開著時改變姿態；測六週月份、從／到切換、多選及取消／完成。
5. 相簿匯入切換預設與自訂範圍；設定頁捲到底。
6. 多 App Split View 分左右位置，各檢查首頁與時間軸的展開→折疊→展開；不能只測 App 內部的分欄。
7. 一般手機與同一 App 多個視窗另外回歸，不能用 Duo 幾何測試代替。

## 維護入口與回退方式

| 要修改的部分 | 程式／測試 |
|---|---|
| 安全分區、鏡頭與導覽列 | [AdaptiveMapLayoutGeometry.swift](../app/wherebear_app/wherebear_app/Components/AdaptiveMapLayoutGeometry.swift)、[AdaptiveMapLayout.swift](../app/wherebear_app/wherebear_app/Components/AdaptiveMapLayout.swift) |
| 抽屜三段位置與可見高度 | [CollapsibleSheetGeometry.swift](../app/wherebear_app/wherebear_app/Components/CollapsibleSheetGeometry.swift)、[CollapsibleSheet.swift](../app/wherebear_app/wherebear_app/Components/CollapsibleSheet.swift) |
| 日期卡片與區間操作 | [AdaptiveDateDialog.swift](../app/wherebear_app/wherebear_app/Components/AdaptiveDateDialog.swift)、[BearCalendar.swift](../app/wherebear_app/wherebear_app/Components/BearCalendar.swift)、[TimelineScreen.swift](../app/wherebear_app/wherebear_app/Screens/TimelineScreen.swift) |
| 幾何回歸 | [AdaptiveMapLayoutChecks.swift](../tests/swift/AdaptiveMapLayoutChecks.swift) |

幾何檢查可在 repo 根目錄獨立執行，不需要模擬器或後端：

```bash
xcrun swiftc \
  app/wherebear_app/wherebear_app/Components/AdaptiveMapLayoutGeometry.swift \
  app/wherebear_app/wherebear_app/Components/CollapsibleSheetGeometry.swift \
  tests/swift/AdaptiveMapLayoutChecks.swift \
  -o /tmp/wherebear-layout-checks
/tmp/wherebear-layout-checks
```

日期卡片的 SwiftUI 渲染測試住在 app 的測試 target（`DateDialogLayoutTests`），需要已包含測試 target 的 dev scheme 與 Debug-Dev 設定。環境選擇依[部署文件](DEPLOYMENT.md)；本專案的一般 Debug 不等於 dev。

大幅調整版面前，建議先提交一個可回退的檢查點。回退應針對相關提交使用 `git revert` 並重新驗證，保留已推送的歷史。截圖、測試產物與本機部署設定留在忽略目錄，不隨文件提交。
