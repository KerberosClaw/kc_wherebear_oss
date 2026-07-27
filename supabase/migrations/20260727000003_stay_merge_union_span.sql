-- kc_wherebear — 配對成功的停留段：時間改「核心窗聯集」，而非「一律用 CLVisit」
--
-- ── 要修的問題 ──
-- stays_for_day 原本「時間邊界一律用 CLVisit、位置與名稱用聚合中心」，前提是「久坐不動時
-- live 幾乎失明、聚出來的段很窄」。p_gap_s 從 30 分放寬到 8 小時（20260727000002）之後前提
-- 反過來：聚合段變成整天，反而被 CLVisit 的短段整個截斷，而且配對到的聚合段會被
-- `where not exists (select 1 from pair …)` 整段丟掉。四天資料裡有 882 分鐘的 live 停留證據
-- 就這樣消失。
--   日間長停   聚合 555 分        vs  CLVisit 21 分        → 顯示 21 分
--   夜間長停   聚合 6 小時 47 分  vs  CLVisit 1 小時 25 分  → 之後六小時消失
--
-- ── 為什麼不是單純取聯集（第一版寫錯，這裡記著）──
-- 🔴 聯集是「單調只增」的：兩邊任何把區間撐大的誤差都被保留，任何把區間收緊的修正都被丟棄。
-- 而這個系統裡「收緊」那一側**恰好是刻意做出來的品質機制**：
--   `visits_close_on_departure_evidence` 算出的 departed_at 是「最後一次還在附近」，
--   那支 migration 的存在理由就是「不要把離場路程算進停留」。
-- 「撐大」那一側**恰好是已知有污染的**：detect_stays 判「同一處」是距**錨點**（群集第一點）
--   150 公尺內，所以人往外走的頭一兩百公尺仍會被吃進同一個群集。
-- 直接取 max 等於系統性地讓噪音永遠贏，把上一支 migration 修好的東西原封放回來。
--
-- 實例（某次短停，實測座標距離；T＝到達）：
--   T+0～T+5 分   離該點 0～5 公尺        ← 真的在那裡
--   T+5 分        CLVisit departed_at      ← 反證式修剪算出的誠實離開時刻（等於某個 live 點）
--   T+18 分       離該點 129 公尺、離下一個地點 82 公尺  ← 人在走路，卻是聚合段的最後一點
--   T+25 分       離下一個地點 5 公尺       ← 到下一個地點了
--   直接取聯集 → 停留 9.6 分變 22.7 分（+137%），多出來的全是走路時間。
--
-- ── 改用「核心窗聯集」──
-- 延伸邊界時不用聚合段的原始首末點，改用「群集時間窗內、且距合併中心 p_core_radius_m 以內」
-- 的 live 點的首末。延伸只吃「人真的在那裡」的證據，離場／接近路段自動排除。
-- 實測 R=60/75/100/120 輸出完全相同（落在平台中央、不是挑中的臨界值），R=150 才退化成
-- 直接聯集 —— 所以 100 是可解釋的選擇，不是憑感覺的常數。
--
-- ── 三道保險 ──
-- 1. to_ts 用顯式 case，**不靠 greatest**：Postgres 的 greatest 會忽略 null
--    （實測 greatest(null::timestamptz, t) = t），直接用會把「還在停留中」寫成「已經離開」。
--    聯集語意上 [a,∞) ∪ [b,c] = [min(a,b),∞)，結束仍是「還在」。
-- 2. dwell_seconds 一起重算：消費端（app 的 dwellText/StayRow、today-stays 讀取口）都直接顯示
--    這個欄位、不從首末反推。作法是在原值上加頭尾差額，未關閉那列「算到 now()／封頂」的
--    語意因此原封不動保留，不能改成單純 to - from。
-- 3. 不越過相鄰的 CLVisit 段：延伸後的結束不超過下一段的開始、開始不早於上一段的結束。
--    現有資料即使不夾也沒有重疊，但實測「把每個群集最後一點往後挪 60 秒」就會出現 2 對重疊，
--    而 60 秒正是標準輪詢的間隔 → 那是常態取樣密度、不是極端擾動。有了夾取，
--    「同一段時間被兩筆停留宣稱」在結構上不可能發生，不必靠參數運氣。
--
-- ── 已驗證不受影響 ──
-- 封頂（visit_open_until）不會被繞過：配對條件要求 v.from_ts < s.to_ts 且 v.from_ts >= arrived_at，
-- 所以聯集終點必然是一筆 captured_at >= arrived_at 的 live 點，一定被封頂的 max(captured_at) 涵蓋。
-- 跨午夜也不受影響：聚合段本身受日界限制、CLVisit 段已被夾在日界內。
-- ⚠️ 但「跨午夜兩天加總＝CLVisit 全長」這條不變式會變成「加總＝聯集全長」，若日後寫測試要照這條。

-- 多一個參數 → 必須先 drop（否則三參數呼叫會在四參數版與五參數版之間 ambiguous）。
drop function if exists public.stays_for_day(uuid,date,text,double precision);

create function public.stays_for_day(
  p_user uuid, p_day date, p_tz text default 'Asia/Taipei',
  p_pair_radius_m double precision default 150,
  p_core_radius_m double precision default 100
)
returns table (
  name text, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision, source text
)
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select row_number() over (order by from_ts, centroid_lat, centroid_lng) as vid, *
    from public.visits_for_day(p_user, p_day, p_tz)
  ),
  s as (
    select row_number() over (order by from_ts) as sid, *
    from public.detect_stays(p_user, p_day, p_tz)
  ),
  pair as (
    select s.sid, v.vid, s.centroid_lat, s.centroid_lng, s.dwell_seconds as s_dwell,
           s.from_ts as s_from, s.to_ts as s_to,
           extract(epoch from (
             least(s.to_ts, coalesce(v.to_ts, s.to_ts)) - greatest(s.from_ts, v.from_ts)
           )) as overlap_s
    from s
    join v on s.from_ts < coalesce(v.to_ts, 'infinity'::timestamptz)
          and v.from_ts < coalesce(s.to_ts, 'infinity'::timestamptz)
          and extensions.st_dwithin(
                extensions.st_setsrid(extensions.st_point(s.centroid_lng, s.centroid_lat), 4326)::extensions.geography,
                extensions.st_setsrid(extensions.st_point(v.centroid_lng, v.centroid_lat), 4326)::extensions.geography,
                p_pair_radius_m)
  ),
  best as (
    select distinct on (vid) vid, sid, centroid_lat, centroid_lng, s_from, s_to
    from pair
    order by vid, overlap_s desc, s_dwell desc
  ),
  base as (
    select v.vid,
           coalesce(b.centroid_lat, v.centroid_lat) as lat,
           coalesce(b.centroid_lng, v.centroid_lng) as lng,
           case when b.vid is null then v.slack_m else 0 end as slack,
           b.s_from, b.s_to,
           v.from_ts as v_from, v.to_ts as v_to, v.dwell_seconds as v_dwell, v.confidence,
           lag(v.to_ts)    over (order by v.from_ts) as prev_to,
           lead(v.from_ts) over (order by v.from_ts) as next_from
    from v left join best b on b.vid = v.vid
  ),
  -- 核心窗：群集時間窗內、且距合併中心 p_core_radius_m 以內的 live 點首末。
  -- 這是「人真的在那裡」的證據範圍；離場／接近路段的點落在圈外、自動不算。
  core as (
    select b.*,
           (select min(h.captured_at) from public.location_history h
             where h.user_id = p_user and h.source = 'live'
               and h.captured_at >= b.s_from and h.captured_at <= b.s_to
               and extensions.st_dwithin(h.geog,
                     extensions.st_setsrid(extensions.st_makepoint(b.lng, b.lat), 4326)::extensions.geography,
                     p_core_radius_m)) as c_from,
           (select max(h.captured_at) from public.location_history h
             where h.user_id = p_user and h.source = 'live'
               and h.captured_at >= b.s_from and h.captured_at <= b.s_to
               and extensions.st_dwithin(h.geog,
                     extensions.st_setsrid(extensions.st_makepoint(b.lng, b.lat), 4326)::extensions.geography,
                     p_core_radius_m)) as c_to
    from base b
  ),
  merged as (
    select c.*,
           -- 開始：往前延伸到核心窗起點，但不早於上一段的結束
           greatest(
             least(c.v_from, coalesce(c.c_from, c.v_from)),
             coalesce(c.prev_to, '-infinity'::timestamptz)
           ) as u_from,
           -- 結束：仍在停留中就維持 null（不可用 greatest，它會吃掉 null）；
           --       否則往後延伸到核心窗終點，但不越過下一段的開始
           case when c.v_to is null then null
                else least(
                       greatest(c.v_to, coalesce(c.c_to, c.v_to)),
                       coalesce(c.next_from, 'infinity'::timestamptz)
                     )
           end as u_to
    from core c
  )
  select public.resolve_name(p_user, m.lat, m.lng, m.slack) as name,
         m.u_from as from_ts,
         m.u_to   as to_ts,
         -- 在原 dwell 上加頭尾差額，不重算 —— 未關閉停留「算到 now()／封頂」的語意因此保留。
         greatest(0,
           m.v_dwell
           + extract(epoch from (m.v_from - m.u_from))
           + case when m.v_to is null then 0 else extract(epoch from (m.u_to - m.v_to)) end
         )::integer as dwell_seconds,
         m.lat as centroid_lat, m.lng as centroid_lng,
         m.confidence, 'visit'::text as source
  from merged m
  union all
  select public.resolve_name(p_user, s.centroid_lat, s.centroid_lng, 0),
         s.from_ts, s.to_ts, s.dwell_seconds, s.centroid_lat, s.centroid_lng, s.confidence, 'live'::text
  from s
  where not exists (select 1 from pair p where p.sid = s.sid)
  union all
  select public.resolve_name(p_user, p.centroid_lat, p.centroid_lng, 0),
         p.from_ts, p.to_ts, p.dwell_seconds, p.centroid_lat, p.centroid_lng, p.confidence, 'photo_import'::text
  from public.photo_points(p_user, p_day, p_tz) p
  order by from_ts asc
$$;

comment on function public.stays_for_day(uuid,date,text,double precision,double precision) is
  '某當地日的合併停留清單：CLVisit 段與 live 聚合段配對後，時間取「核心窗聯集」（只用距中心 p_core_radius_m 內的 live 點延伸，排除離場／接近路段），位置與名稱用 live 中心；延伸不越過相鄰段；未關閉的停留 to_ts 維持 null。未配對的 live 段原樣保留；相簿匯入點獨立。';

revoke all on function public.stays_for_day(uuid,date,text,double precision,double precision) from public;
grant execute on function public.stays_for_day(uuid,date,text,double precision,double precision) to service_role;
