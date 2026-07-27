-- kc_wherebear — 「多久沒回報算離開」從 30 分鐘放寬到 8 小時
--
-- 為什麼（對真實資料實測）：detect_stays 的 p_gap_s 原本 1800 秒。那個值假設「沒回報＝離開」，
-- 但這個 app 的回報本來就會安靜很久 —— 人不動時 significant-change 不觸發，前景輪詢又只在
-- app 於前景時跑。結果是**同一個地方被手機的沉默切成碎片**，嚴重時整段消失。
--
-- 實例一（整夜消失）：深夜短暫停止回報後隨即重開，人整夜待在同一處。iOS 不會為「你本來
--   就在那裡」補送到達事件（已實測坐實），所以 visits 這條線沒東西；live 點之間空了 70 分、
--   241 分、29 分，全部超過 30 分門檻 → 該段在時間軸上整整六小時空白。
--
-- 實例二（一整天被切三段）：同一個地點在同一天被切成 08:45-09:00 / 09:48-10:19 / 17:34-18:01，
--   其實從頭到尾沒離開。久坐不動時最長沉默 **7 小時 15 分**（10:19→17:34）。
--
-- ── 為什麼 8 小時 ──
-- 取「實測最長合法沉默」為下界：坐著不動一整個下午就是 7 小時 15 分，6 小時蓋不住（實測 6 小時
-- 仍把同一天切成兩段）。8 小時是能覆蓋一整個白天／整夜的最小整數小時值。
--
-- ── 為什麼放寬不會把不同地方黏在一起 ──
-- 群集的中斷條件是「時間差超過 p_gap_s」**或**「距離超過 p_radius_m(150m)」。放寬時間門檻不影響
-- 距離門檻 —— 真的移動到別處，距離那關就先斷了。實測驗證（同一天合併起來的兩段）：
--   地點 A（夜間長停）  窗內 7 個點，離錨點 >150m 的 0 個，最遠 110m
--   地點 B（日間長停）  窗內 35 個點，離錨點 >150m 的 0 個，最遠 135m
--   同期 visits（iOS 自己記的停留）在這兩段區間內也沒有出現別的地點。
--
-- 🔴 殘留風險（沒解、明講）：若使用者在沉默期間去了 **500 公尺內** 的地方，
-- significant-change 本來就不觸發、不會留下任何點，那趟會被併進停留裡、停留時間高估。
-- 這是定位機制本身的盲區，不是這個門檻造成的；把門檻調回 30 分鐘也救不了那種情況，
-- 只會反過來把真實停留切碎（見上面兩個實例）。

create or replace function public.detect_stays(
  p_user        uuid,
  p_day         date,
  p_tz          text default 'Asia/Taipei',
  p_radius_m    double precision default 150,
  p_min_dwell_s integer default 600,
  p_gap_s       integer default 28800   -- 8 小時（原 1800＝30 分）
)
returns table (
  from_ts       timestamptz,
  to_ts         timestamptz,
  dwell_seconds integer,
  centroid_lat  double precision,
  centroid_lng  double precision,
  confidence    double precision
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  day_start timestamptz;
  day_end   timestamptz;
  r         record;
  a_lat double precision; a_lng double precision;
  c_from timestamptz; c_to timestamptz;
  c_sum_lat double precision; c_sum_lng double precision; c_n int;
  prev_ts timestamptz;
  d double precision;
  have boolean := false;
begin
  day_start := (p_day::text || ' 00:00:00')::timestamp at time zone p_tz;
  day_end   := day_start + interval '1 day';

  for r in
    select lat, lng, captured_at
    from public.location_history
    where user_id = p_user
      and captured_at >= day_start
      and captured_at <  day_end
    order by captured_at asc
  loop
    if not have then
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at; have := true;
      continue;
    end if;

    if extract(epoch from (r.captured_at - prev_ts)) > p_gap_s then
      if extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
        from_ts := c_from; to_ts := c_to;
        dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
        centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
        confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
        return next;
      end if;
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at;
      continue;
    end if;

    d := extensions.st_distance(
      extensions.st_setsrid(extensions.st_point(a_lng, a_lat), 4326)::extensions.geography,
      extensions.st_setsrid(extensions.st_point(r.lng, r.lat), 4326)::extensions.geography
    );
    if d <= p_radius_m then
      c_to := r.captured_at;
      c_sum_lat := c_sum_lat + r.lat; c_sum_lng := c_sum_lng + r.lng; c_n := c_n + 1;
      prev_ts := r.captured_at;
    else
      if extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
        from_ts := c_from; to_ts := c_to;
        dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
        centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
        confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
        return next;
      end if;
      a_lat := r.lat; a_lng := r.lng;
      c_from := r.captured_at; c_to := r.captured_at;
      c_sum_lat := r.lat; c_sum_lng := r.lng; c_n := 1;
      prev_ts := r.captured_at;
    end if;
  end loop;

  if have and extract(epoch from (c_to - c_from)) >= p_min_dwell_s then
    from_ts := c_from; to_ts := c_to;
    dwell_seconds := floor(extract(epoch from (c_to - c_from)))::int;
    centroid_lat := c_sum_lat / c_n; centroid_lng := c_sum_lng / c_n;
    confidence := least(1.0, greatest(0.2, c_n::double precision / 6.0));
    return next;
  end if;
  return;
end $$;

comment on function public.detect_stays(uuid,date,text,double precision,integer,integer) is
  '停留段偵測（依當地日）。p_gap_s 預設 8 小時：回報本來就會長時間安靜（人不動時 significant-change 不觸發），30 分鐘會把整夜／整個工作天切碎。不同地點靠 p_radius_m 的距離門檻擋，不靠時間門檻。service_role only.';
