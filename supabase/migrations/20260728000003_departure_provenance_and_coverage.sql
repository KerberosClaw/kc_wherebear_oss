-- kc_wherebear — 離開時刻的「來源」與「觀測邊界」分離
--
-- 修的兩個問題：
--   A. `visits.departed_at` 由四種來源共寫，departure 事件在「null→非 null」那一刻發出且不可更正
--      → 誰先寫誰決定事件內容；後來被更權威的來源覆寫，下游永遠不知道。
--   B. 按「停止回報」時 app 會 PATCH `departed_at = now()`，被當成物理離開發出 departure
--      → 事件時刻會比真正的離開晚（誤差取決於當次情形）；若在尚未離開時按停止，
--        更會宣稱「離開了該地點」而人還在。
--
-- ⚠️ 這個設計有兩個很容易踩進去的陷阱，兩個都會造成**靜默失敗**（沒有錯誤訊息、只是事件不見了）：
-- 「來源標記升級不會發生」與「事件出口不只一個、只堵一個沒用」。
-- 兩者的成因與避開方式寫在下面對應的段落，改動前務必看過。
--
-- 🔴 **相依：20260728000002 必須先套用。**
-- 本支重新宣告 visits_close_on_departure_evidence()，內容已含 20260728000002 的「觀測到的遠離時長」
-- 判準 ＋ 本支新增的顯式來源標記。若順序顛倒，20260728000002 會把這支函式換回**沒有來源標記**的
-- 版本，導致推測型關閉被誤判成 iOS 自報 —— 靜默且難查。

-- ── ① Schema ─────────────────────────────────────────────────────────────────
-- 🔴 eligibility 用兩段式 default 做 grandfather：既有列 false、新列 true，
--    且 ADD COLUMN 常數 default 不重寫表、不觸發 moddatetime → 既有列的 updated_at 不會被刷掉。
alter table public.visits add column if not exists departure_source text not null default 'unknown';
alter table public.visits add column if not exists coverage_ended_at timestamptz;
alter table public.visits add column if not exists departure_event_eligible boolean not null default false;
alter table public.visits alter column departure_event_eligible set default true;

do $$ begin
  alter table public.visits add constraint visits_departure_source_chk
    check (departure_source in ('ios_clvisit','live_evidence','next_arrival','unknown'));
exception when duplicate_object then null; end $$;

comment on column public.visits.departure_source is
  '這一列的 departed_at 是誰寫的。判定依 method＋path＋role 的傳輸形狀，非不可偽造的 attestation；認不出來一律 unknown。';
comment on column public.visits.coverage_ended_at is
  '觀測邊界：使用者按「停止回報」的時刻。**不是**物理離開時刻。不會被日後的 location_history 推動。';
comment on column public.visits.departure_event_eligible is
  '本列是否有資格發 departure 事件。部署當下既有的列一律 false，避免 outbox 重送補發過期事件。';

-- 🔴 欄位級 REVOKE 對已持有 table-level 權限的角色無效（撤完 has_column_privilege 仍是 true）。
--    必須先收回整表、再用欄位白名單授權。
revoke insert, update on public.visits from authenticated;
grant insert (user_id, lat, lng, accuracy, arrived_at, departed_at) on public.visits to authenticated;
grant update (user_id, lat, lng, accuracy, arrived_at, departed_at) on public.visits to authenticated;

-- ── ② 證據窗抽成唯一定義 ─────────────────────────────────────────────────────
-- 原本 adjudicate_visit_place 與 visit_place_vote 各複製一份、遲早再次分裂。
-- 同時修正：只有權威來源（iOS 自報）的 departed_at 才可以截斷證據窗；
-- 推測型關閉若太早會砍掉命名證據且永久定案。
create or replace function public.visit_evidence_window(p_visit_id bigint)
returns table (win_from timestamptz, win_to timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select v.arrived_at - make_interval(secs => pol.pre_window_s),
         least(v.arrived_at + make_interval(secs => pol.post_window_s),
               case when v.departure_source = 'ios_clvisit'
                    then coalesce(v.departed_at, 'infinity'::timestamptz)
                    else 'infinity'::timestamptz end)
  from public.visits v
  cross join lateral (select * from public.visit_event_policies
                       where active order by version desc limit 1) pol
  where v.id = p_visit_id
$$;

comment on function public.visit_evidence_window(bigint) is
  '一段停留的地名證據時窗（唯一定義，裁決與讀取層共用）。只有 departure_source=ios_clvisit 時才用 departed_at 截上緣。';

revoke all on function public.visit_evidence_window(bigint) from public;
grant execute on function public.visit_evidence_window(bigint) to service_role;

-- ── 裁決改吃唯一定義的證據窗 ─────────────────────────────────────────────────
create or replace function public.adjudicate_visit_place(p_visit_id bigint)
returns public.visit_event_decisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v            public.visits%rowtype;
  pol          public.visit_event_policies%rowtype;
  legacy_name  text;
  w            record;
  top_name     text;
  top_n        integer := 0;
  named_kinds  integer := 0;
  st           text;
  rc           text;
  out_name     text;
  out_lm       bigint;
  out_n        integer := 0;
  d            public.visit_event_decisions%rowtype;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then
    raise exception 'visit % 不存在', p_visit_id;
  end if;
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then
    raise exception '沒有 active 的 visit_event_policies';
  end if;

  legacy_name := public.resolve_alias(v.user_id, v.lat, v.lng, coalesce(v.accuracy, 0));
  select * into w from public.visit_evidence_window(p_visit_id);

  with ev as (
    select public.resolve_alias(v.user_id, h.lat, h.lng, 0) as nm
    from public.location_history h
    where h.user_id = v.user_id
      and h.captured_at between w.win_from and w.win_to
      and coalesce(h.accuracy, 1e9) <= pol.max_live_accuracy_m
  ), tally as (
    select nm, count(*) as n from ev where nm is not null group by nm
  )
  select t.nm, t.n, (select count(*) from tally)
    into top_name, top_n, named_kinds
  from tally t order by t.n desc, t.nm asc limit 1;

  top_n       := coalesce(top_n, 0);
  named_kinds := coalesce(named_kinds, 0);

  if legacy_name is not null and top_name is not distinct from legacy_name
     and top_n >= pol.min_agree_points and named_kinds = 1 then
    st := 'resolved'; rc := 'clvisit_live_agree';
    out_name := top_name; out_n := top_n;
  elsif top_name is not null and top_n >= pol.min_consensus_points and named_kinds = 1 then
    st := 'resolved';
    rc := case when legacy_name is null or legacy_name = top_name
               then 'live_consensus' else 'live_consensus_override' end;
    out_name := top_name; out_n := top_n;
  elsif named_kinds > 1 then
    st := 'unresolved'; rc := 'conflicting_landmark_evidence'; out_n := top_n;
  elsif legacy_name is not null or top_name is not null then
    st := 'unresolved'; rc := 'insufficient_live_evidence'; out_n := top_n;
  else
    st := 'unresolved'; rc := 'no_landmark_candidate'; out_n := 0;
  end if;

  if out_name is not null then
    select l.id into out_lm from public.landmarks l
    where l.user_id = v.user_id and l.alias = out_name
    order by l.id limit 1;
  end if;

  insert into public.visit_event_decisions as t
    (visit_id, user_id, decision_status, reason_code, legacy_would_emit,
     landmark_id, name_snapshot, evidence_count, policy_version, decided_at)
  values
    (v.id, v.user_id, st, rc, legacy_name is not null,
     out_lm, out_name, out_n, pol.version, now())
  on conflict (visit_id) do update set
    decision_status   = excluded.decision_status,
    reason_code       = excluded.reason_code,
    legacy_would_emit = excluded.legacy_would_emit,
    landmark_id       = excluded.landmark_id,
    name_snapshot     = excluded.name_snapshot,
    evidence_count    = excluded.evidence_count,
    policy_version    = excluded.policy_version,
    decided_at        = now()
  where t.decision_status = 'pending'
  returning * into d;

  if d.visit_id is null then
    select * into d from public.visit_event_decisions where visit_id = p_visit_id;
  end if;
  return d;
end $$;

-- ── 讀取層投票也吃同一支證據窗 ───────────────────────────────────────────────
create or replace function public.visit_place_vote(p_visit_id bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v public.visits%rowtype; pol public.visit_event_policies%rowtype;
  legacy_name text; w record;
  top_name text; top_n integer := 0; named_kinds integer := 0;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then return null; end if;
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then return null; end if;

  legacy_name := public.resolve_alias(v.user_id, v.lat, v.lng, coalesce(v.accuracy, 0));
  select * into w from public.visit_evidence_window(p_visit_id);

  with ev as (
    select public.resolve_alias(v.user_id, h.lat, h.lng, 0) as nm
    from public.location_history h
    where h.user_id = v.user_id
      and h.captured_at between w.win_from and w.win_to
      and coalesce(h.accuracy, 1e9) <= pol.max_live_accuracy_m
  ), tally as (select nm, count(*) as n from ev where nm is not null group by nm)
  select t.nm, t.n, (select count(*) from tally) into top_name, top_n, named_kinds
  from tally t order by t.n desc, t.nm asc limit 1;
  top_n := coalesce(top_n,0); named_kinds := coalesce(named_kinds,0);

  if legacy_name is not null and top_name is not distinct from legacy_name
     and top_n >= pol.min_agree_points and named_kinds = 1 then return top_name;
  elsif top_name is not null and top_n >= pol.min_consensus_points and named_kinds = 1 then return top_name;
  else return null; end if;
end $$;

-- ── 後端兩個 writer 顯式標記來源（擋掉外層 HTTP method 誤判）──────────────────
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
  gap_min    constant integer := 15;
begin
  here := extensions.st_setsrid(extensions.st_makepoint(new.lng, new.lat), 4326)::extensions.geography;

  for v in
    select id, lat, lng, accuracy, arrived_at
      from public.visits
     where user_id = new.user_id and departed_at is null and arrived_at < new.captured_at
  loop
    there := extensions.st_setsrid(extensions.st_makepoint(v.lng, v.lat), 4326)::extensions.geography;

    select max(l.radius) into lm_radius
      from public.landmarks l
     where l.user_id = new.user_id
       and extensions.st_dwithin(l.geog, there, l.radius + coalesce(v.accuracy, 0));

    far_m := greatest(120, coalesce(lm_radius, 0) + 50,
                      coalesce(v.accuracy, 0) + coalesce(new.accuracy, 0) + 100);

    continue when extensions.st_distance(here, there) <= far_m;

    select max(h.captured_at) into last_near
      from public.location_history h
     where h.user_id = new.user_id and h.source = 'live'
       and h.captured_at >= v.arrived_at
       and extensions.st_dwithin(h.geog, there, far_m);
    last_near := coalesce(last_near, v.arrived_at);

    -- 20260728000002：時間判準看「觀測到的遠離時長」，沉默不累積
    select min(h.captured_at) into first_far
      from public.location_history h
     where h.user_id = new.user_id and h.source = 'live'
       and h.captured_at > last_near and h.captured_at <= new.captured_at
       and extensions.st_distance(h.geog, there) > greatest(
             120, coalesce(lm_radius, 0) + 50,
             coalesce(v.accuracy, 0) + coalesce(h.accuracy, 0) + 100);
    first_far := coalesce(first_far, new.captured_at);

    continue when new.captured_at - first_far < make_interval(mins => gap_min);

    -- 🔴 顯式標來源：同一個 UPDATE 帶上，BEFORE 觸發器看得到 → 不會被外層 POST 誤判成 iOS
    update public.visits
       set departed_at = last_near, departure_source = 'live_evidence'
     where id = v.id and departed_at is null;
  end loop;

  return new;
end $$;

-- ── 端點形狀判定（刻意不寫死路徑前綴）─────────────────────────────────────────
-- 🔴 不同 PostgREST 版本／部署可能給 `/visits` 或 `/rest/v1/visits`。寫死前綴的話，
--    若部署環境給的格式不同，會讓**所有寫入都變成 unknown、departure 事件全部不發** —— 靜默失效。
--    改成尾段比對 ＋ 明確排除 RPC（RPC 也是 POST，只看 method 會誤判）。
create or replace function public.is_visits_endpoint(p text)
returns boolean
language sql
immutable
as $$
  select p is not null
     and p not like '%/rpc/%'
     and split_part(p, '?', 1) ~ '(^|/)visits$'
$$;

comment on function public.is_visits_endpoint(text) is
  'PostgREST 的 request.path 是不是 visits 表端點。容忍前綴差異、排除 RPC；認不出來一律回 false（→ 來源落 unknown）。';

-- ── ③ 來源歸屬 ＋ 停止回報改寫（單一 BEFORE 觸發器）──────────────────────────
-- 🔴 必須 security invoker：definer 會讓 current_user 變成 owner，所有 iOS 寫入都被誤判成 unknown。
create or replace function public.set_departure_provenance() returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  m  text := current_setting('request.method', true);
  p  text := current_setting('request.path', true);
  ts timestamptz;
begin
  -- ① 停止回報：PATCH 就地改寫成觀測邊界，不碰物理離開時刻。必須先短路，否則會把既有來源降級。
  if tg_op = 'UPDATE'
     and m = 'PATCH' and public.is_visits_endpoint(p) and current_user = 'authenticated'
     and new.departed_at is distinct from old.departed_at
  then
    -- 🔴 null 必須先擋：least(null, x) = x，不擋會讓夾取失效
    if new.departed_at is null or old.coverage_ended_at is not null then
      return null;                      -- 整列跳過（已有邊界 → 不刷 updated_at、不進 transition table）
    end if;
    ts := greatest(old.arrived_at,
                   least(new.departed_at, statement_timestamp() + interval '60 seconds'));
    new.coverage_ended_at := ts;
    new.departed_at       := old.departed_at;
    return new;                         -- 不再落入下面的來源判定
  end if;

  -- ② 來源判定：只在 departed_at 被寫入或改變時作用
  if not (
       (tg_op = 'INSERT' and new.departed_at is not null)
    or (tg_op = 'UPDATE' and new.departed_at is distinct from old.departed_at)
  ) then
    return new;
  end if;

  -- 後端函式顯式帶的值優先（live_evidence / next_arrival）
  if tg_op = 'UPDATE'
     and new.departure_source is distinct from old.departure_source
     and new.departure_source in ('live_evidence','next_arrival') then
    return new;
  end if;
  if tg_op = 'INSERT' and new.departure_source in ('live_evidence','next_arrival') then
    return new;
  end if;

  -- 手機自報：method ＋ path ＋ role 三者同時成立才算（RPC 也是 POST，只看 method 會誤判）
  if m = 'POST' and public.is_visits_endpoint(p) and current_user = 'authenticated' then
    new.departure_source := 'ios_clvisit';          -- 無論舊值為何都升級
  else
    new.departure_source := 'unknown';
  end if;
  return new;
end $$;

comment on function public.set_departure_provenance() is
  '標記 departed_at 的寫入來源，並把「停止回報」的 PATCH 就地改寫成 coverage_ended_at。必須 security invoker（current_user 要是真實呼叫者）。';

-- 命名讓它排在 set_updated_at 之前 → 回傳 null 跳過整列時不會刷 updated_at
drop trigger if exists set_departure_provenance_t on public.visits;
create trigger set_departure_provenance_t
  before insert or update on public.visits
  for each row execute function public.set_departure_provenance();

-- ── ④ departure 唯一關卡：原子 claim ＋ 不吞例外的送出 ────────────────────────
-- 🔴 realtime.send() 內含 EXCEPTION WHEN OTHERS → RAISE WARNING，
--    送失敗不會回滾 → claim 會被錯誤保留。這裡改直接寫入 realtime.messages、外層不捕捉例外。
create or replace function public.realtime_send_strict(p_payload jsonb, p_event text, p_topic text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  msg_id  uuid := gen_random_uuid();
  final_p jsonb;
begin
  final_p := case when p_payload ? 'id' then p_payload
                  else jsonb_set(p_payload, '{id}', to_jsonb(msg_id)) end;
  perform set_config('realtime.topic', p_topic, true);
  insert into realtime.messages (id, payload, event, topic, private, extension)
  values (msg_id, final_p, p_event, p_topic, true, 'broadcast');
end $$;

comment on function public.realtime_send_strict(jsonb,text,text) is
  '與 realtime.send 相同，但**不吞例外** —— 送出失敗必須讓整個交易回滾，否則「已送出」旗標會被錯誤保留。';

create or replace function public.visit_event_emit(p_visit_id bigint, p_kind text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v       public.visits%rowtype;
  claimed public.visit_event_decisions%rowtype;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then return false; end if;

  if p_kind = 'departure' then
    -- 🔴 原子 claim：把冪等、隱私閘、來源、eligibility、資料合法性全放進同一個 UPDATE。
    --    三個呼叫點（INSERT 分支／UPDATE 分支／pg_cron）即使忘了擋也拿不到 claim。
    update public.visit_event_decisions d
       set departure_sent_at = now()
      from public.visits vv
     where d.visit_id = p_visit_id and vv.id = d.visit_id
       and d.departure_sent_at is null
       and d.decision_status <> 'pending'
       and (d.decision_status = 'resolved' or d.legacy_would_emit)
       and vv.departed_at is not null
       and vv.departed_at > vv.arrived_at
       and vv.departure_source = 'ios_clvisit'
       and vv.departure_event_eligible
    returning d.* into claimed;
  else
    update public.visit_event_decisions d
       set arrival_sent_at = now()
     where d.visit_id = p_visit_id
       and d.arrival_sent_at is null
       and d.decision_status <> 'pending'
       and (d.decision_status = 'resolved' or d.legacy_would_emit)
    returning d.* into claimed;
  end if;

  if claimed.visit_id is null then return false; end if;

  perform public.realtime_send_strict(
    jsonb_build_object(
      'schema_version',    case when claimed.decision_status = 'resolved' then 1 else 2 end,
      'kind',              p_kind,
      'name',              claimed.name_snapshot,
      'visit_id',          v.id,
      'arrived_at',        v.arrived_at,
      'departed_at',       v.departed_at,
      'dwell_s',           case when v.departed_at is not null
                                then extract(epoch from (v.departed_at - v.arrived_at))::int end,
      'decision_status',   claimed.decision_status,
      'reason_code',       claimed.reason_code,
      'evidence_count',    claimed.evidence_count,
      'algorithm_version', claimed.algorithm_version,
      'policy_version',    claimed.policy_version
    ),
    'visit',
    'wb:events:' || v.user_id::text
  );
  return true;
end $$;

comment on function public.visit_event_emit(bigint,text) is
  '發送到達／離開事件。冪等靠原子 claim（先搶旗標再送、送失敗整個交易回滾）。departure 另要求 departure_source=ios_clvisit 且 eligible。';

-- ── ⑤ 單一合併 AFTER 觸發器 ─────────────────────────────────────────────────
-- 🔴 不可用 AFTER UPDATE OF departure_source 當條件：它看的是原始 SQL 的 target list，
--    BEFORE 觸發器改的 NEW.departure_source 不會讓它觸發。
create or replace function public.visit_event_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  pol       public.visit_event_policies%rowtype;
  closed_now boolean;
  upgraded   boolean;
  retry      boolean;
begin
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if pol.version is null then return new; end if;

  if tg_op = 'INSERT' then
    insert into public.visit_event_decisions (visit_id, user_id) values (new.id, new.user_id)
      on conflict (visit_id) do nothing;
  end if;

  closed_now := (tg_op = 'INSERT' and new.departed_at is not null)
             or (tg_op = 'UPDATE' and old.departed_at is null and new.departed_at is not null);
  upgraded   := (tg_op = 'UPDATE' and old.departure_source is distinct from 'ios_clvisit'
                                  and new.departure_source = 'ios_clvisit');
  retry      := (tg_op = 'UPDATE' and new.departure_source = 'ios_clvisit'
                                  and new.departed_at is not null
                                  and new.departed_at is distinct from old.departed_at);

  -- 到達裁決：權威來源可立即裁決；非權威來源在截止點之前保持 pending，交給 cron
  -- （否則推測型早關會用不完整的證據永久定案）
  if tg_op = 'INSERT' or closed_now then
    if new.departure_source = 'ios_clvisit'
       or now() >= new.arrived_at + make_interval(secs => pol.post_window_s) then
      perform public.adjudicate_visit_place(new.id);
      perform public.visit_event_emit(new.id, 'arrival');
    end if;
  end if;

  if closed_now or upgraded or retry then
    perform public.visit_event_emit(new.id, 'departure');   -- 由 ④ 的原子 claim 自己擋
  end if;

  return new;
end $$;

comment on function public.visit_event_broadcast() is
  '到達建立候選；權威來源或已過截止點才裁決並補發到達；離開／來源升級為 iOS 時嘗試發離開（實際能不能發由 visit_event_emit 決定）。';

drop trigger if exists visit_event_broadcast_t on public.visits;
create trigger visit_event_broadcast_t
  after insert or update of departed_at, departure_source on public.visits
  for each row execute function public.visit_event_broadcast();

-- ── ⑥ coverage_ended 事件（statement-level ＋ transition table）───────────────
-- 🔴 transition table 不能搭 column list，所以不寫 `of coverage_ended_at`，改在函式內判 null→非 null。
create or replace function public.visits_emit_coverage_ended() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r    record;
  lastp record;
begin
  for r in
    select n.user_id, max(n.coverage_ended_at) as occurred_at
      from new_rows n join old_rows o on o.id = n.id
     where o.coverage_ended_at is null and n.coverage_ended_at is not null
     group by n.user_id
  loop
    -- 最後一個「被觀測到」的點：live 歷史 ∪ 當前位置，取 <= occurred_at 的最新一筆。
    -- 刻意不吃 photo_import；也刻意不往前搜尋「最後一個有名字的地方」（會洩漏前一個地點）。
    select x.captured_at, public.resolve_alias(r.user_id, x.lat, x.lng, 0) as nm
      into lastp
    from (
      select h.captured_at, h.lat, h.lng, 0 as hot_rank, h.id
        from public.location_history h
       where h.user_id = r.user_id and h.source = 'live'
      union all
      select c.captured_at, c.lat, c.lng, 1, 0::bigint
        from public.current_location c
       where c.user_id = r.user_id
    ) x
    where x.captured_at <= r.occurred_at
    order by x.captured_at desc, x.hot_rank desc, x.id desc
    limit 1;

    perform public.realtime_send_strict(
      jsonb_build_object(
        'schema_version',    3,
        'kind',              'coverage_ended',
        'occurred_at',       r.occurred_at,
        'last_observed_at',  lastp.captured_at,
        'last_known_name',   lastp.nm,
        'reason',            'reporting_stop',
        'source_confidence', 'inferred_from_http_shape'
      ),
      'visit',
      'wb:events:' || r.user_id::text
    );
  end loop;
  return null;
end $$;

comment on function public.visits_emit_coverage_ended() is
  '回報結束事件（每個 user 一則、不是每列一則）。只宣告觀測終止，不冒充物理離開：不得帶 dwell 或座標。';

drop trigger if exists visits_coverage_ended_stmt_t on public.visits;
create trigger visits_coverage_ended_stmt_t
  after update on public.visits
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.visits_emit_coverage_ended();

-- ── ⑦ 讀取層的有效結束時刻（source-aware）───────────────────────────────────
-- 🔴 不可無條件 least(departed_at, coverage, cap)：真實 iOS 長停留晚於 24h cap 時會被截短。
drop function if exists public.visits_for_day(uuid,date,text,integer);
create function public.visits_for_day(
  p_user uuid, p_day date, p_tz text default 'Asia/Taipei', p_open_grace_s integer default 86400)
returns table (
  visit_id bigint, from_ts timestamptz, to_ts timestamptz, dwell_seconds integer,
  centroid_lat double precision, centroid_lng double precision, confidence double precision,
  slack_m double precision
)
language sql
stable
security definer
set search_path = ''
as $$
  with b as (
    select (p_day::text || ' 00:00:00')::timestamp at time zone p_tz as day_start,
           ((p_day::text || ' 00:00:00')::timestamp at time zone p_tz) + interval '1 day' as day_end
  ),
  x as (
    select v.*,
           public.visit_open_until(p_user, v.arrived_at, p_open_grace_s) as capped_at,
           -- 有效結束：coverage 是硬邊界；有物理離開時取兩者較早；都沒有才走封頂
           case
             when v.coverage_ended_at is not null and v.departed_at is not null
               then least(v.coverage_ended_at, v.departed_at)
             when v.coverage_ended_at is not null then v.coverage_ended_at
             else v.departed_at
           end as eff_end
    from public.visits v
    where v.user_id = p_user
  )
  select x.id,
         greatest(x.arrived_at, b.day_start),
         case
           when x.eff_end is not null then least(x.eff_end, b.day_end)
           when x.capped_at <= now()  then least(x.capped_at, b.day_end)
           when b.day_end <= now()    then b.day_end
           else null
         end,
         greatest(0, extract(epoch from (
           least(coalesce(x.eff_end, least(now(), x.capped_at)), b.day_end)
           - greatest(x.arrived_at, b.day_start)
         )))::integer,
         x.lat, x.lng, 1.0::double precision, x.accuracy
  from x, b
  where x.arrived_at < b.day_end
    and coalesce(x.eff_end, least(now(), x.capped_at)) >= b.day_start
$$;

comment on function public.visits_for_day(uuid,date,text,integer) is
  'CLVisit 停留與當地日的交集，夾在當日邊界內。結束時刻＝coverage 邊界／物理離開／封頂（依序），coverage 不會被日後的 location_history 推動。';

revoke all on function public.visits_for_day(uuid,date,text,integer) from public;
grant execute on function public.visits_for_day(uuid,date,text,integer) to authenticated, service_role;

-- ── ⑧ 已定案就不重新投票（地名與已發事件永遠同源）───────────────────────────
-- 🔴 不能用 coalesce：unresolved 的 name_snapshot 是 null，會 fall through 回去重算。
create or replace function public.stays_for_day(
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
    from pair order by vid, overlap_s desc, s_dwell desc, sid asc
  ),
  base as (
    select v.vid, v.visit_id,
           coalesce(b.centroid_lat, v.centroid_lat) as lat,
           coalesce(b.centroid_lng, v.centroid_lng) as lng,
           case when b.vid is null then v.slack_m else 0 end as slack,
           b.s_from, b.s_to,
           v.from_ts as v_from, v.to_ts as v_to, v.dwell_seconds as v_dwell, v.confidence,
           lag(v.to_ts)    over (order by v.from_ts) as prev_to,
           lead(v.from_ts) over (order by v.from_ts) as next_from
    from v left join best b on b.vid = v.vid
  ),
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
           greatest(least(c.v_from, coalesce(c.c_from, c.v_from)),
                    coalesce(c.prev_to, '-infinity'::timestamptz)) as u_from,
           case when c.v_to is null then null
                else least(greatest(c.v_to, coalesce(c.c_to, c.v_to)),
                           coalesce(c.next_from, 'infinity'::timestamptz)) end as u_to
    from core c
  )
  -- 🔴 只有 resolved 才鎖住名字 —— 那是唯一「已經對外宣告過名字」的狀態，時間軸必須跟它同源。
  -- unresolved 對外宣告的是「我判不出來」（v2 事件 name=null 或根本沒發），並沒有宣告任何名字，
  -- 所以時間軸沿用自己的最佳猜測不構成矛盾。🔴 若連 unresolved 也鎖，那些停留會憑空變成無名。
  select case
           when d.decision_status = 'resolved' then d.name_snapshot
           else coalesce(public.visit_place_vote(m.visit_id),
                         public.resolve_name(p_user, m.lat, m.lng, m.slack))
         end as name,
         m.u_from as from_ts,
         m.u_to   as to_ts,
         greatest(0,
           m.v_dwell
           + extract(epoch from (m.v_from - m.u_from))
           + case when m.v_to is null then 0 else extract(epoch from (m.u_to - m.v_to)) end
         )::integer as dwell_seconds,
         m.lat as centroid_lat, m.lng as centroid_lng,
         m.confidence, 'visit'::text as source
  from merged m
  left join public.visit_event_decisions d
         on d.visit_id = m.visit_id and d.user_id = p_user
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
  '某當地日的合併停留清單。地名：已定案（resolved/unresolved）一律用裁決快照、不重新投票 → 與已發事件永遠同源；尚未定案才當場投票或用座標現算。';

revoke all on function public.stays_for_day(uuid,date,text,double precision,double precision) from public;
grant execute on function public.stays_for_day(uuid,date,text,double precision,double precision) to service_role;

-- ── 新到達關舊停留：同樣顯式標來源 ───────────────────────────────────────────
-- 🔴 這支跑在 app 的 POST /visits 交易裡 —— 不顯式標的話，被它關掉的舊停留會被
--    來源判定誤認成「手機自報的離開」，正是要避免的誤判。
create or replace function public.visits_autoclose_stale() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.visits v
     set departed_at = least(new.arrived_at,
                             public.visit_open_until(v.user_id, v.arrived_at)),
         departure_source = 'next_arrival'
   where v.user_id = new.user_id
     and v.departed_at is null
     and v.arrived_at < new.arrived_at;
  return new;
end $$;
