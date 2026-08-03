-- 未送出的 unresolved 裁決＝可晉升的暫態
--
-- 問題：地名裁決是「一次定案、永不重看」。使用者「先到新地方、再把它加成地標」這個
-- 最自然的操作順序，會讓那一段停留永遠拿不到到達與離開推播——因為裁決在地標出生之前
-- 就跑完了，而發送條件要求「已解析」。讀取層每次查詢都用當下的地標表重算，所以時間軸
-- 看得到地名、推播卻沒有；兩層時間語意不同，靜默無人察覺。
--
-- 這份 migration 建立的規則：
--   resolved                        → 終態
--   任一 *_sent_at 非 null          → 終態（已對外宣告，收不回）
--   unresolved 且兩個旗標都是 null  → **可重新考慮，但只能晉升成 resolved**
--
-- 刻意不做的事：
--   ✗ 不在 landmarks 上掛同步觸發器。那會把地標存檔綁進事件管線——重判、搶旗標、寫
--     realtime 全在同一筆交易裡，任何一段失敗使用者看到的是「地標存不了」。改由 app
--     在存檔成功後另開一個請求呼叫 RPC，失敗不影響地標。
--   ✗ 不把 unresolved 重設回 pending。那會讓 cron、重判、離開觸發器三邊同時取得處理
--     資格，還會毀掉稽核語意。改成 unresolved → resolved 的原子比較並設定。
--   ✗ 不覆寫初次的 decided_at 與 legacy_would_emit。它們解釋的正是「當初為何沒發」。
--   ✗ 不放寬 min_consensus_points。單一 live 點在無 CLVisit 同名佐證時判錯過（見
--     20260727000004 的門檻依據），放寬等於拿「少漏幾則」換「很有把握地說錯地方」。

-- ── F1 補償事件的新鮮度界線 ───────────────────────────────────────────────────
-- 下游消費端把超過 30 分鐘的事件靜靜丟棄，**但水位照樣推進**：補一則陳年事件不只零效益，
-- 它還可能成為「收到時間最新」的那一則，把同批尚未處理的有效事件一起跨過去。
-- 所以過期就不要進即時通道；留 5 分鐘傳遞餘裕，不要剛好卡滿。
alter table public.visit_event_policies
  add column if not exists emit_horizon_s integer not null default 1500;

comment on column public.visit_event_policies.emit_horizon_s is
  '事件可進即時通道的年齡上限（秒）。arrival 看 arrived_at、departure 看 departed_at。'
  '刻意小於下游的 30 分鐘新鮮度門檻，留傳遞餘裕。過期＝不送，且**不寫 sent_at**（假寫會讓日後真的該發時被冪等擋掉）。';

-- ── F2 證據窗：可顯式指定政策版本 ─────────────────────────────────────────────
-- 原本恆讀 active policy。要做「假如當時這個地標已存在，原本的規則會怎麼判」這種
-- counterfactual 重判，就必須鎖住當初那一版；否則哪天門檻改版，翻案結果會同時受
-- 地標與政策兩個變數影響，稽核上說不清是誰造成的。
create or replace function public.visit_evidence_window(p_visit_id bigint, p_policy_version integer)
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
                       where version = p_policy_version) pol
  where v.id = p_visit_id
$$;

comment on function public.visit_evidence_window(bigint, integer) is
  '證據窗的顯式版本形式。單參數版本＝用當下 active 政策（原行為，未變）。';

revoke all on function public.visit_evidence_window(bigint, integer) from public;
grant execute on function public.visit_evidence_window(bigint, integer) to service_role;

-- ── F3 裁決的純計算層（唯一分支邏輯來源）─────────────────────────────────────
-- 把「算出這段停留該叫什麼」從「寫進資料庫」裡抽出來。原本的分支邏輯原封不動搬過來，
-- 只是改成可指定政策版本、且不寫任何東西。adjudicate 與 reconsider 共用同一份，
-- 免得兩邊各留一份、遲早分裂（這正是 20260728000003 把證據窗抽成唯一定義的理由）。
create or replace function public.visit_place_decide(p_visit_id bigint, p_policy_version integer)
returns table (
  status         text,
  reason_code    text,
  out_name       text,
  out_landmark   bigint,
  evidence_count integer,
  legacy_hit     boolean
)
language plpgsql
stable
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
  pick_name    text;
  lm           bigint;
  n_out        integer := 0;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then
    raise exception 'visit % 不存在', p_visit_id;
  end if;
  select * into pol from public.visit_event_policies where version = p_policy_version;
  if not found then
    raise exception '沒有版本 % 的 visit_event_policies', p_policy_version;
  end if;

  legacy_name := public.resolve_alias(v.user_id, v.lat, v.lng, coalesce(v.accuracy, 0));
  select * into w from public.visit_evidence_window(p_visit_id, p_policy_version);

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

  -- 分支順序與 20260728000003 完全一致，不得更動語意
  if legacy_name is not null and top_name is not distinct from legacy_name
     and top_n >= pol.min_agree_points and named_kinds = 1 then
    st := 'resolved'; rc := 'clvisit_live_agree';
    pick_name := top_name; n_out := top_n;
  elsif top_name is not null and top_n >= pol.min_consensus_points and named_kinds = 1 then
    st := 'resolved';
    rc := case when legacy_name is null or legacy_name = top_name
               then 'live_consensus' else 'live_consensus_override' end;
    pick_name := top_name; n_out := top_n;
  elsif named_kinds > 1 then
    st := 'unresolved'; rc := 'conflicting_landmark_evidence'; n_out := top_n;
  elsif legacy_name is not null or top_name is not null then
    st := 'unresolved'; rc := 'insufficient_live_evidence'; n_out := top_n;
  else
    st := 'unresolved'; rc := 'no_landmark_candidate'; n_out := 0;
  end if;

  if pick_name is not null then
    select l.id into lm from public.landmarks l
    where l.user_id = v.user_id and l.alias = pick_name
    order by l.id limit 1;
  end if;

  return query select st, rc, pick_name, lm, n_out, (legacy_name is not null);
end $$;

comment on function public.visit_place_decide(bigint, integer) is
  '純計算：這段停留在指定政策版本下該判成什麼。不寫任何東西。裁決與重判共用的唯一分支邏輯。';

revoke all on function public.visit_place_decide(bigint, integer) from public;
grant execute on function public.visit_place_decide(bigint, integer) to service_role;

-- ── F4 裁決稽核（append-only）────────────────────────────────────────────────
-- 舊 revision 不覆寫。要能回答「這段停留的名字是什麼時候、因為什麼、用哪一版規則定的」。
create table if not exists public.visit_decision_revisions (
  id              bigint generated by default as identity primary key,
  visit_id        bigint      not null references public.visits(id) on delete cascade,
  user_id         uuid        not null references auth.users(id)   on delete cascade,
  revision        integer     not null,
  trigger_source  text        not null,
  decision_status text        not null,
  reason_code     text,
  name_snapshot   text,
  evidence_count  integer,
  algorithm_version text,
  policy_version  integer,
  created_at      timestamptz not null default now(),
  unique (visit_id, revision)
);

do $$ begin
  alter table public.visit_decision_revisions
    add constraint visit_decision_revisions_trigger_chk
    check (trigger_source in ('initial','landmark_change','departure_recheck',
                              'user_assignment','policy_upgrade'));
exception when duplicate_object then null; end $$;

create index if not exists visit_decision_revisions_visit_idx
  on public.visit_decision_revisions (visit_id, revision);

comment on table public.visit_decision_revisions is
  '裁決的 append-only 歷程。初次裁決記 initial，之後每次晉升各記一筆。舊列永不覆寫。';

alter table public.visit_decision_revisions enable row level security;

drop policy if exists "own decision revisions" on public.visit_decision_revisions;
create policy "own decision revisions" on public.visit_decision_revisions
  for select using ((select auth.uid()) = user_id);

revoke insert, update, delete on public.visit_decision_revisions from authenticated;
grant select on public.visit_decision_revisions to authenticated;


-- 🔴 對既有資料庫回填「初次」revision。
--    這張表是新建的，套用當下是空的。若不回填，既有的 unresolved 一旦被晉升，
--    revision 1 記到的會是**晉升後**的狀態，當初為什麼判不出名字就永久消失了 ——
--    而那正好是這張表存在的唯一理由。
insert into public.visit_decision_revisions
  (visit_id, user_id, revision, trigger_source, decision_status, reason_code,
   name_snapshot, evidence_count, algorithm_version, policy_version, created_at)
select d.visit_id, d.user_id, 1, 'initial', d.decision_status, d.reason_code,
       d.name_snapshot, d.evidence_count, d.algorithm_version, d.policy_version,
       coalesce(d.decided_at, d.created_at)
from public.visit_event_decisions d
on conflict (visit_id, revision) do nothing;

-- 記一筆 revision（下一個編號）。內部用，不對外。
create or replace function public.record_decision_revision(p_visit_id bigint, p_trigger text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.visit_decision_revisions
    (visit_id, user_id, revision, trigger_source, decision_status, reason_code,
     name_snapshot, evidence_count, algorithm_version, policy_version)
  select d.visit_id, d.user_id,
         coalesce((select max(r.revision) from public.visit_decision_revisions r
                    where r.visit_id = d.visit_id), 0) + 1,
         p_trigger, d.decision_status, d.reason_code, d.name_snapshot,
         d.evidence_count, d.algorithm_version, d.policy_version
  from public.visit_event_decisions d
  where d.visit_id = p_visit_id
$$;

revoke all on function public.record_decision_revision(bigint, text) from public;
grant execute on function public.record_decision_revision(bigint, text) to service_role;

-- ── F5 裁決改吃純計算層（行為不變）───────────────────────────────────────────
create or replace function public.adjudicate_visit_place(p_visit_id bigint)
returns public.visit_event_decisions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v    public.visits%rowtype;
  pol  public.visit_event_policies%rowtype;
  r    record;
  d    public.visit_event_decisions%rowtype;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then
    raise exception 'visit % 不存在', p_visit_id;
  end if;
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then
    raise exception '沒有 active 的 visit_event_policies';
  end if;

  select * into r from public.visit_place_decide(p_visit_id, pol.version);

  insert into public.visit_event_decisions as t
    (visit_id, user_id, decision_status, reason_code, legacy_would_emit,
     landmark_id, name_snapshot, evidence_count, policy_version, decided_at)
  values
    (v.id, v.user_id, r.status, r.reason_code, r.legacy_hit,
     r.out_landmark, r.out_name, r.evidence_count, pol.version, now())
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
  else
    perform public.record_decision_revision(p_visit_id, 'initial');
  end if;
  return d;
end $$;

comment on function public.adjudicate_visit_place(bigint) is
  '對一段停留做初次裁決（只覆寫 pending，行為未變）。分支邏輯已抽到 visit_place_decide。';

-- ── F6 重判：只能晉升，不能倒退 ──────────────────────────────────────────────
create or replace function public.reconsider_unresolved_visit(p_visit_id bigint, p_trigger text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  d  public.visit_event_decisions%rowtype;
  r  record;
begin
  if p_trigger not in ('landmark_change','departure_recheck','user_assignment','policy_upgrade') then
    raise exception '不認得的重判來源 %', p_trigger;
  end if;

  -- 鎖住這一列再判，避免離開觸發器與 RPC 同時翻同一段
  select * into d from public.visit_event_decisions
   where visit_id = p_visit_id for update;
  if not found then return false; end if;

  -- 終態守門：resolved 是終態；已對外宣告過也是終態
  if d.decision_status <> 'unresolved'
     or d.arrival_sent_at is not null
     or d.departure_sent_at is not null then
    return false;
  end if;

  -- 🔴 鎖住當初那一版政策：這是 counterfactual（「若當時地標已存在會怎麼判」），
  --    不是政策升版。政策升版必須是獨立、可查、明確指定目標版本的動作。
  select * into r from public.visit_place_decide(p_visit_id, d.policy_version);

  if r.status <> 'resolved' then
    return false;                       -- 只能晉升；判不出來就維持原樣、不留噪音
  end if;

  -- 🔴 覆寫之前先把「當初的樣子」留下來。少了這一步，被晉升的那些列在稽核上
  --    只剩晉升後的狀態，「當初為何沒發」就查不到了。
  if not exists (select 1 from public.visit_decision_revisions where visit_id = p_visit_id) then
    perform public.record_decision_revision(p_visit_id, 'initial');
  end if;

  -- 原子比較並設定。不覆寫 decided_at 與 legacy_would_emit —— 它們解釋「當初為何沒發」。
  update public.visit_event_decisions
     set decision_status = 'resolved',
         reason_code     = r.reason_code,
         name_snapshot   = r.out_name,
         landmark_id     = r.out_landmark,
         evidence_count  = r.evidence_count
   where visit_id = p_visit_id
     and decision_status = 'unresolved'
     and arrival_sent_at is null
     and departure_sent_at is null;

  if not found then return false; end if;

  perform public.record_decision_revision(p_visit_id, p_trigger);
  return true;
end $$;

comment on function public.reconsider_unresolved_visit(bigint, text) is
  '把「尚未送出任何事件的 unresolved」重新考慮一次，只允許晉升成 resolved。'
  '鎖原政策版本（counterfactual，非政策升版）；不覆寫初次 decided_at 與 legacy_would_emit。';

revoke all on function public.reconsider_unresolved_visit(bigint, text) from public;
grant execute on function public.reconsider_unresolved_visit(bigint, text) to service_role;

-- ── F7 送出加上新鮮度界線 ────────────────────────────────────────────────────
-- claim 條件本身不動（冪等、隱私閘、來源、eligibility 全在同一個 UPDATE 裡）；
-- 只多一道年齡上限，且 arrival 與 departure 各看自己的時刻。
create or replace function public.visit_event_emit(p_visit_id bigint, p_kind text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v        public.visits%rowtype;
  claimed  public.visit_event_decisions%rowtype;
  horizon  integer;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then return false; end if;

  select pol.emit_horizon_s into horizon
    from public.visit_event_policies pol
   where pol.active order by pol.version desc limit 1;
  horizon := coalesce(horizon, 1500);

  if p_kind = 'departure' then
    -- 🔴 過期就不進即時通道，而且**不寫 sent_at**：假寫會讓日後真的該發時被冪等擋掉。
    if v.departed_at is null or v.departed_at < now() - make_interval(secs => horizon) then
      return false;
    end if;
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
    if v.arrived_at < now() - make_interval(secs => horizon) then
      return false;
    end if;
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

comment on function public.visit_event_emit(bigint, text) is
  '發送到達／離開事件。冪等靠原子 claim。departure 另要求 departure_source=ios_clvisit 且 eligible。'
  '兩者都受 emit_horizon_s 年齡上限約束：過期不送、且不寫 sent_at。';

-- ── F8 權威離開時的安全網 ────────────────────────────────────────────────────
-- 這條單獨就補得回「地標建晚了」那一整類：離開的時候地標通常已經存在。
-- 它同時補掉「app 沒呼叫 RPC」（舊版、離線、使用者從地圖建地標）的洞。
create or replace function public.visit_event_broadcast() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  pol        public.visit_event_policies%rowtype;
  closed_now boolean;
  upgraded   boolean;
  retry      boolean;
begin
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then return new; end if;

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

  if tg_op = 'INSERT' or closed_now then
    if new.departure_source = 'ios_clvisit'
       or now() >= new.arrived_at + make_interval(secs => pol.post_window_s) then
      perform public.adjudicate_visit_place(new.id);
      perform public.visit_event_emit(new.id, 'arrival');
    end if;
  end if;

  if closed_now or upgraded or retry then
    -- 🔴 安全網：離開的時候，當初判不出名字的地標可能已經被建起來了。
    --    只動「仍 unresolved 且兩個旗標都空」的段，其餘原樣。
    perform public.reconsider_unresolved_visit(new.id, 'departure_recheck');
    perform public.visit_event_emit(new.id, 'departure');
  end if;

  return new;
end $$;

comment on function public.visit_event_broadcast() is
  '到達建立候選；權威來源或已過截止點才裁決並補發到達。離開時先對仍 unresolved 且未送的段重判一次'
  '（地標常常是到達之後才建的），再嘗試發離開；能不能發由 visit_event_emit 決定。';

-- ── F9.5 晉升之後只補「一則有意義的」事件 ─────────────────────────────────────
-- 🔴 一段**已經結束**的停留補事件時，不可以同批補到達＋離開：那會連推
--    「他剛到了 X」＋「他剛離開 X」兩則，但人早就走了，到達那則是廢話。
--    正常的即時路徑不受影響 —— 那裡到達與離開本來就發生在不同時刻。
--    這支只用在「補發」路徑（使用者存完地標觸發的重判、人為指定）。
create or replace function public.emit_after_promotion(p_visit_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  closed boolean;
begin
  select departed_at is not null into closed from public.visits where id = p_visit_id;
  if closed is null then return false; end if;
  if closed then
    -- 已結束 → 只補離開（最新、也是唯一還有意義的那一則）
    return public.visit_event_emit(p_visit_id, 'departure');
  else
    -- 還開著 → 只補到達；未來真的離開時，正常路徑會自己發離開
    return public.visit_event_emit(p_visit_id, 'arrival');
  end if;
end $$;

comment on function public.emit_after_promotion(bigint) is
  '晉升後的補發：已結束的停留只補離開、還開著的只補到達。避免同批推出「剛到又剛離開」這種矛盾組合。'
  '能不能真的送仍由 emit_horizon_s 年齡上限決定。';

revoke all on function public.emit_after_promotion(bigint) from public;
grant execute on function public.emit_after_promotion(bigint) to service_role;

-- ── F9 使用者自己觸發的重判（不收 user 參數）─────────────────────────────────
-- 🔴 只認 auth.uid()。repo 已經因為「definer ＋ 呼叫端可傳 p_user」踩過跨帳號讀取
--    （見 20260728000005），這裡不重蹈覆轍。
create or replace function public.my_reconsider_recent_visits()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  me        uuid := (select auth.uid());
  vid       bigint;
  promoted  integer := 0;
begin
  if me is null then
    raise exception '需要登入身分';
  end if;

  -- 候選：自己的、仍 unresolved、兩個旗標都空，且「還開著」或「還在可補發的年齡內」。
  -- 兩個界線刻意分開：即使到達已過期，現在重判仍能救未來那一則離開。
  for vid in
    select v.id
      from public.visits v
      join public.visit_event_decisions d on d.visit_id = v.id
     where v.user_id = me
       and d.decision_status = 'unresolved'
       and d.arrival_sent_at is null
       and d.departure_sent_at is null
       and (v.departed_at is null or v.departed_at >= now() - interval '7 days')
     order by v.arrived_at desc
     limit 200
  loop
    if public.reconsider_unresolved_visit(vid, 'landmark_change') then
      promoted := promoted + 1;
      -- 只補一則有意義的（已結束→離開、還開著→到達）；能不能真的送由新鮮度界線決定
      perform public.emit_after_promotion(vid);
    end if;
  end loop;

  return promoted;
end $$;

comment on function public.my_reconsider_recent_visits() is
  '使用者存完地標後由 app 另開請求呼叫：把自己近期「未送出的 unresolved」重新考慮一次。'
  '冪等、可重試、失敗不影響地標儲存。不接受任何 user 參數，只認 auth.uid()。';

revoke all on function public.my_reconsider_recent_visits() from public;
grant execute on function public.my_reconsider_recent_visits() to authenticated;
