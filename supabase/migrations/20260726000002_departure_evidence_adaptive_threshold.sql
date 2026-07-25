-- kc_wherebear — 反證式修剪的距離門檻改成自適應（前一支寫死 250 公尺，太粗）
--
-- 為什麼馬上就改：20260726000001 是為了「人在 209 公尺外的另一家店、iOS 卻不發新到達」
-- 這個實例做的，但門檻寫死 250 公尺 —— **剛好擋不住當初要修的那個案例**。
-- 209 公尺在定位誤差只有 8～15 公尺的情況下毫無歧義，卻被一個憑感覺挑的常數擋掉。
--
-- 改成三者取大：
--   a) 120 公尺（地板，避免病態小值）
--   b) 該停留若落在某個命名地標內 → 該地標半徑 ＋ 50 公尺
--      （公園之類半徑大的地方，要真的走出去才算離開）
--   c) 停留本身的誤差 ＋ 這筆定位的誤差 ＋ 100 公尺
--      （兩邊定位都很爛時自動放寬，不會因為誤差就誤判）
--
-- 真正防誤關的其實是那 15 分鐘的寬限，不是距離 —— 距離只負責排除 GPS 抖動。

create or replace function public.visits_close_on_departure_evidence() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v          record;
  here       extensions.geography;
  there      extensions.geography;
  last_near  timestamptz;
  lm_radius  double precision;
  far_m      double precision;
  gap_min    constant integer := 15;   -- 走開多久才算真的離開
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

    continue when extensions.st_distance(here, there) <= far_m;

    select max(h.captured_at) into last_near
      from public.location_history h
     where h.user_id = new.user_id
       and h.source = 'live'
       and h.captured_at >= v.arrived_at
       and extensions.st_dwithin(h.geog, there, far_m);
    last_near := coalesce(last_near, v.arrived_at);

    continue when new.captured_at - last_near < make_interval(mins => gap_min);

    update public.visits set departed_at = last_near where id = v.id and departed_at is null;
  end loop;

  return new;
end $$;

comment on function public.visits_close_on_departure_evidence() is
  '反證式修剪：當前位置持續遠離某段未關閉的停留時，以「最後一次還在附近」的時刻關閉它。距離門檻自適應（地板 120m / 地標半徑+50 / 兩邊誤差+100 取大），防誤關主要靠 15 分鐘寬限。';
