-- kc_wherebear — 到達／離開事件即時通道（D13 的資料庫半邊）
--
-- 形狀：visits 變動 → 觸發器在資料庫端解析地標 → 命中才用 realtime.send() 發私有 broadcast。
--
-- 為什麼不用 postgres_changes 訂閱 visits：
--   1. 訂閱 visits 需要一把能看 visits 的 JWT，而那把 JWT 對 PostgREST 一樣有效
--      → 消費端從「只能打兩支窄讀口」膨脹成「能讀寫該使用者所有的表」。
--   2. 「是不是命名地點」要查 landmarks，訂閱端得自己讀 landmarks（同一個膨脹問題）。
--   改用 broadcast 後兩件事都消失：判定留在資料庫、payload 只帶解析後的名字。
--
-- 授權（realtime.messages 預設 RLS 全拒，規則完全自訂）：
--   放行角色＝anon（該角色在 public schema 一無所有——實測打 visits / landmarks /
--   location_history / current_location 全數 permission denied），身分靠自訂 claim
--   wb_uid 綁 topic。公開的 anon key 沒有這個 claim → 永遠對不上任何 topic。
--   短效 token 由換發 Edge Function 簽發（api key → 查 api_keys → 簽 wb_uid）。
--
-- payload 不含原始座標：下游只吃「名字」，對齊既有「不餵 raw 座標給下游」的紀律。

-- ── 授權：只放行「自己那條 topic」───────────────────────────────────────────
drop policy if exists "own visit events" on realtime.messages;
create policy "own visit events" on realtime.messages
  for select to anon
  using ( realtime.topic() = 'wb:events:' || coalesce(auth.jwt() ->> 'wb_uid', '') );

-- ── 事件產生 ────────────────────────────────────────────────────────────────
-- 到達＝INSERT；離開＝departed_at 由 null 變成有值的那一次 UPDATE（見 D14：改鍵後
-- 離開走 UPDATE 而非 INSERT，所以這兩個時機各自乾淨、不會重複觸發）。
create or replace function public.visit_event_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  nm   text;
  kind text;
begin
  if tg_op = 'INSERT' then
    kind := 'arrival';
  elsif tg_op = 'UPDATE' and old.departed_at is null and new.departed_at is not null then
    kind := 'departure';
  else
    return new;                       -- 其餘 UPDATE（補 accuracy、改座標…）不是事件
  end if;

  -- 只有使用者命名過的地點才發。未命名 → 靜默（實測：到達陌生點收到 0 則）
  nm := public.resolve_alias(new.user_id, new.lat, new.lng, coalesce(new.accuracy, 0));
  if nm is null then
    return new;
  end if;

  perform realtime.send(
    jsonb_build_object(
      'schema_version', 1,
      'kind',        kind,
      'name',        nm,
      'visit_id',    new.id,
      'arrived_at',  new.arrived_at,
      'departed_at', new.departed_at,
      -- 離開才算得出停留時長；到達時為 null
      'dwell_s',     case when new.departed_at is not null
                          then extract(epoch from (new.departed_at - new.arrived_at))::int
                     end
    ),
    'visit',
    'wb:events:' || new.user_id::text,
    true
  );
  return new;
end $$;

comment on function public.visit_event_broadcast() is
  '到達／離開事件：解析 landmarks alias，命中才發私有 broadcast 到 wb:events:<user_id>。payload 不含原始座標。';

drop trigger if exists visit_event_broadcast_t on public.visits;
create trigger visit_event_broadcast_t
  after insert or update of departed_at on public.visits
  for each row execute function public.visit_event_broadcast();
