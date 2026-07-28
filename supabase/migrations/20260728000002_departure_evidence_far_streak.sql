-- kc_wherebear — 反證式修剪的 15 分鐘寬限：從「最後一次還在附近到現在」改成「觀測到人在外面持續多久」
--
-- ── 要修的問題 ──
-- 20260726000002 的註解寫的是「持續遠離 15 分鐘」，但實作是：
--     continue when new.captured_at - last_near < interval '15 minutes';
-- 也就是「**最後一次還在附近**到現在超過 15 分鐘」。這句話對「手機整夜沒回報」同樣成立
-- → 一筆遠處的點 ＋ 前面一段長沉默就通過判準，沉默被當成遠離。
--
-- 實例（實測；時刻為相對位移）：
--   T+0h00m      CLVisit 到達某個命名地標
--   T+4h44m      最後一筆落在該地標附近的 live 點
--                （之後裝置沉默 7 小時 51 分 —— 長時間靜止時的正常省電行為）
--   T+12h35m     裝置恢復回報一次，距該地標 409 公尺
--   T+12h35m+2s  ← 舊判準通過（最後近點到現在 8 小時 > 15 分）→ 關在 T+4h44m
--                  departure 事件立刻送出，payload 宣稱離開時刻是 T+4h44m
--   （其後 16 秒）← CLVisit 自報的真正離開時刻 T+12h34m 進來，覆寫 departed_at
--   結果：時間軸顯示到 T+12h34m（對），已送出的事件說 T+4h44m（早了 7 小時 50 分），
--         且事件一次性、不重播。
--
-- ── 改法 ──
-- 判準改成「**第一筆觀測到人在外面**到現在超過 15 分鐘」：
--     continue when new.captured_at - first_far < interval '15 minutes';
-- 沉默期間沒有任何觀測 → 不會累積這個時間 → 需要真的看到人在外面待滿 15 分鐘才關。
-- 關閉時刻仍取 last_near（不變），所以既有的 departed_at 值不會改變。
--
-- ── 為什麼不把觸發器搬到 location_history ──
-- 直覺的作法是搬過去（那樣「當下這筆」就已經在歷史表裡、算式比較單純），但那會改變行為：
--   1. 離線補送只寫 location_history（`Logic.swift:388`）→ 搬過去後每筆補送都會觸發判斷，
--      現行不會。行為面多一條路徑，與「不許退化」的目標相反。
--   2. location_history 還存相簿匯入的點（`source='photo_import'`），搬過去必須另外過濾。
-- 這裡改成把「當下這筆」當成最新一次觀測（歷史表查不到就用 new.captured_at 當 first_far），
-- 觸發器留在 current_location 原地，行為改變面最小。
--
-- ── 影響範圍 ──
-- 絕大多數停留是由裝置自己送 CLVisit 離開關閉的，走不到這條規則；真正靠這條規則關閉的是少數，
-- 也就是「人已離開、但 iOS 始終不發新的 CLVisit」那種情形（見 20260726000001 的 209 公尺實例）。
-- 對那種情形逐點重放（時刻為相對位移）：
--   last_near        S+10m10s
--   第一筆觀測到在外  S+23m20s（129 公尺，該點門檻 124）
--   舊判準關閉時機    S+30m06s
--   新判準關閉時機    S+55m57s   ← 晚了 25 分 51 秒（S+34m45s 之後有 21 分鐘沒有任何回報）
--   departed_at      S+10m10s   ← **兩者完全相同**
-- 對長沉默那種情形：恢復回報的第一筆只有一次觀測 → 不關 → CLVisit 隨後送來真正的離開時刻，
-- 由它關閉並送出正確事件。
--
-- ⚠️ 代價講清楚：靠證據推測的離開，事件會晚發。晚多久取決於「下一個回報什麼時候來」，
-- 15 分鐘只是下限（上面那個重放例子實際晚了 26 分鐘）。**內容不變、只是晚講。**
-- 這只影響「裝置從頭到尾沒送 CLVisit 離開」的少數情況。要調整就改 gap_min。
--
-- ── 逐條確認不退化 ──
-- 1. 20260725000004 visits_autoclose_stale：不同支觸發器，未動 → 新的到達仍能關掉孤兒停留。
-- 2. 20260726000001 的 209 公尺實例：仍會關、departed_at 仍是 S+10m10s（上面逐點重放驗過），
--    只是事件晚 26 分鐘。原始問題（永遠不關、宣稱人還在小店兩個半小時）沒有回來。
-- 3. 20260726000002 的自適應距離門檻：完全保留（120 / 地標半徑+50 / 兩邊誤差+100 取大）。
--    這支只改時間判準，距離判準一個字沒動。
-- 4. 20260727000001 visit_open_stay_cap：未動。證據不足而暫時不關的停留，仍受「最後回報 +24h」封頂。
-- 5. 20260727000002 detect_stays gap 8h：未動（那支管聚合段怎麼斷開，與 visits 的關閉時刻不同層）。
-- 6. 20260727000003 核心窗聯集：未動。關閉時刻仍是 last_near，聯集規則吃到的輸入不變。
-- 7. 20260727000004 事件裁決：未動。冪等鍵、已定案不重播、pg_cron flush 全部原樣；
--    事件數量不變（每段仍最多 arrival/departure 各一），只是證據型 departure 的發出時刻延後。
-- 8. 20260728000001 停留清單地名優先序：未動。
-- 9. 下游消費者的喚醒額度：不增加事件、不重複推播，只可能延後。
-- 10. 隱私閘：這支完全不碰 alias / landmark 命名判斷，陌生地點仍靜默。

create or replace function public.visits_close_on_departure_evidence() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v          record;
  here       extensions.geography;
  there      extensions.geography;
  last_near  timestamptz;
  first_far  timestamptz;
  lm_radius  double precision;
  far_m      double precision;
  gap_min    constant integer := 15;   -- 觀測到人在外面持續多久才算真的離開
begin
  here := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;

  for v in
    select id, lat, lng, accuracy, arrived_at
      from public.visits
     where user_id = new.user_id
       and departed_at is null
       and arrived_at < new.captured_at
  loop
    there := extensions.st_setsrid(extensions.st_makepoint(v.lng, v.lat), 4326)::extensions.geography;

    -- 這段停留落在哪個命名地標裡（有的話，要走出它的半徑才算離開）
    select max(l.radius) into lm_radius
      from public.landmarks l
     where l.user_id = new.user_id
       and extensions.st_dwithin(l.geog, there, l.radius + coalesce(v.accuracy, 0));

    far_m := greatest(
      120,
      coalesce(lm_radius, 0) + 50,
      coalesce(v.accuracy, 0) + coalesce(new.accuracy, 0) + 100
    );

    -- 條件 1（未改）：當下位置離那段停留夠遠
    continue when extensions.st_distance(here, there) <= far_m;

    -- 最後一次還在那附近是什麼時候（未改 —— 關閉時刻取這個值，所以既有 departed_at 不變）
    select max(h.captured_at) into last_near
      from public.location_history h
     where h.user_id = new.user_id
       and h.source = 'live'
       and h.captured_at >= v.arrived_at
       and extensions.st_dwithin(h.geog, there, far_m);
    last_near := coalesce(last_near, v.arrived_at);

    -- 🔴 條件 2（本支的改動）：第一筆「觀測到人在外面」是什麼時候
    -- 每個點用它自己的誤差算門檻 —— 問的是「那一刻那筆觀測本身是否構成遠離」。
    select min(h.captured_at) into first_far
      from public.location_history h
     where h.user_id = new.user_id
       and h.source = 'live'
       and h.captured_at > last_near
       and h.captured_at <= new.captured_at
       and extensions.st_distance(h.geog, there) > greatest(
             120,
             coalesce(lm_radius, 0) + 50,
             coalesce(v.accuracy, 0) + coalesce(h.accuracy, 0) + 100
           );
    -- 歷史表裡查不到 → 當下這筆就是第一筆觀測到的遠離
    -- （app 先 POST current_location、再寫 location_history，所以觸發當下它還沒進歷史表）
    first_far := coalesce(first_far, new.captured_at);

    -- 沉默期間沒有任何觀測 → 不會累積這段時間 → 沉默不再被當成遠離
    continue when new.captured_at - first_far < make_interval(mins => gap_min);

    update public.visits set departed_at = last_near where id = v.id and departed_at is null;
  end loop;

  return new;
end $$;

comment on function public.visits_close_on_departure_evidence() is
  '反證式修剪：當前位置遠離某段未關閉的停留、且「已觀測到人在外面」持續超過 15 分鐘時，以「最後一次還在附近」的時刻關閉它。距離門檻自適應（地板 120m / 地標半徑+50 / 兩邊誤差+100 取大）。時間判準看的是觀測到的遠離時長，不是最後近點到現在的時長 —— 手機沉默期間沒有觀測，不會累積。';
