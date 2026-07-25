-- kc_wherebear — 反證式修剪：live 位置證明人已經走了，就把還開著的停留關掉
--
-- 修的問題（2026-07-25 深夜實測）：
--   21:43 CLVisit 記錄到達某家小店。21:53 之後 live 點顯示人已離開，
--   22:13 起穩定停在 209 公尺外的另一家店，**連續兩個半小時**。但 iOS 從頭到尾
--   沒有發出新的 CLVisit 到達——209 公尺太短，不足以讓它認為換了一個區域。
--   結果：該列 departed_at 永遠是 null，時間軸與下游一直宣稱人還在拉麵店，
--   而同一份資料裡的「當前位置」卻正確指向另一家店。兩個來源互相打架。
--
--   前一支 migration（20260725000004）用「新的到達」當關閉證據，但這個情境根本
--   沒有新到達，所以救不到。這支補的是另一種證據：**人現在明明在別的地方**。
--
-- 判準（三個條件同時成立才關，寧可晚關也不要誤關）：
--   1. 目前位置離該停留 > 250 公尺 ＋ 這筆定位的誤差（GPS 抖動一兩百公尺不算數）
--   2. 距離「最後一次還在那附近」已經超過 15 分鐘（短暫走開買個東西不算離開）
--   3. 目前這筆定位本身夠新（由觸發時機保證：它就是剛寫進來的那筆）
--
-- 關閉時刻取「最後一次還在附近的 live 點」，不是現在——那才是誠實的離開時間，
-- 用現在會把中間那段路程算進停留、高估時長。
--
-- 與真實離開投遞的關係：同 20260725000004——若稍後真的收到 CLVisit 離開，
-- upsert 會覆蓋成真值；事件觸發條件是「由 null 變有值」，此時已非 null → 不重播。

create or replace function public.visits_close_on_departure_evidence() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v          record;
  here       extensions.geography;
  last_near  timestamptz;
  gap_min    constant integer := 15;    -- 走開多久才算真的離開
  far_m      constant integer := 250;   -- 多遠才算「不在那裡」
begin
  here := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;

  for v in
    select id, lat, lng, arrived_at
      from public.visits
     where user_id = new.user_id
       and departed_at is null
       and arrived_at < new.captured_at
  loop
    -- 條件 1：現在離那段停留夠遠
    continue when extensions.st_distance(
        here,
        extensions.st_setsrid(extensions.st_makepoint(v.lng, v.lat), 4326)::extensions.geography
      ) <= far_m + coalesce(new.accuracy, 0);

    -- 最後一次還在那附近是什麼時候（沒有的話就用到達時刻當下限）
    select max(h.captured_at) into last_near
      from public.location_history h
     where h.user_id = new.user_id
       and h.source = 'live'
       and h.captured_at >= v.arrived_at
       and extensions.st_dwithin(
             h.geog,
             extensions.st_setsrid(extensions.st_makepoint(v.lng, v.lat), 4326)::extensions.geography,
             far_m);
    last_near := coalesce(last_near, v.arrived_at);

    -- 條件 2：走開夠久（避免繞去對街買個東西就被判定離開）
    continue when new.captured_at - last_near < make_interval(mins => gap_min);

    update public.visits set departed_at = last_near where id = v.id and departed_at is null;
  end loop;

  return new;
end $$;

comment on function public.visits_close_on_departure_evidence() is
  '反證式修剪：當前位置持續遠離某段未關閉的停留時，以「最後一次還在附近」的時刻關閉它。補 CLVisit 對短距離移動（實測 209 公尺）不發新到達、導致停留永遠開著的缺口。';

drop trigger if exists visits_close_on_departure_evidence_t on public.current_location;
create trigger visits_close_on_departure_evidence_t
  after insert or update on public.current_location
  for each row execute function public.visits_close_on_departure_evidence();
