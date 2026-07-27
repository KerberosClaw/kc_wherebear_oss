-- kc_wherebear — 事件地名改由「裁決」產生（D16）
--
-- 病灶：`visits` 那一列同時是「停留身分」「最新一次 CLVisit 座標的容器」「事件名稱的即時
-- 計算依據」。第二個角色會被離開回呼覆寫（D14 的鍵不含座標是刻意的），而第三個角色每次發射
-- 都重算 → visit_id 穩定、名字卻不穩定。實例：同一段停留到達解出 A、離開解出 B。
--
-- 讀取層（D14 的 stays_for_day）早就是「CLVisit 管時間、live 聚合管位置與名稱」；事件層沒沿用
-- 同一套裁決，才在同一個系統裡長出兩套真相。本 migration 把事件層對齊過去。
--
-- 形狀：到達只建立「待裁決」→ 以時窗內的 live 點群為證據裁決一次 → 結果存下來（含名字快照）
--       → 離開沿用，不再拿離開回呼的新座標重新命名。
--
-- 🔴 隱私不變式（本 migration 刻意不放寬）：只對「現行系統本來就會發事件的那些停留」說話。
--    判準＝`legacy_would_emit`（CLVisit 座標有沒有命中地標）。裁決不出名字時發的是「不具名事件」，
--    不是對陌生地點開一條新的事件流。事件的**涵蓋範圍與現行完全相同**，只有內容變誠實。
--
-- 🔴 為什麼「證據不足就靜默」不能單獨上：下游看到的「什麼都沒有」現在同時代表
--    「關掉回報／app 被回收／沒移動」三種成因；再加一種「有停留但判不出名字」會讓那片空白更不可解，
--    而下游被追問空白時的失效模式正是「編一個」。所以不具名事件（v2）與靜默語意必須同一版上線。

-- ── 門檻參數：版本化、不原地改 ───────────────────────────────────────────────
-- 原地改門檻會讓歷史事件無法重現當時用的判準。要調就新增一列、把舊的 active 關掉。
create table if not exists public.visit_event_policies (
  version               integer primary key,
  active                boolean     not null default false,
  pre_window_s          integer     not null,   -- 證據時窗：到達前
  post_window_s         integer     not null,   -- 證據時窗：到達後（也是裁決截止點）
  min_agree_points      integer     not null,   -- CLVisit 與 live 一致時，需要幾筆 live
  min_consensus_points  integer     not null,   -- 純靠 live 共識（含推翻 CLVisit）時需要幾筆
  max_live_accuracy_m   double precision not null,  -- 誤差大於此的 live 點不採信
  created_at            timestamptz not null default now()
);

comment on table public.visit_event_policies is
  '事件地名裁決的門檻（版本化）。調參＝新增一列並切換 active，不可原地改：否則歷史事件無法重現判準。';

-- v1 預設值。門檻取自對 prod 最近四天 28 次到達的唯讀回放：
--   有 live 證據 23／證據不足 5／證據自相矛盾 0／與現行答案不同 2（其一正是誤判案例，裁決後答對）。
-- min_consensus_points 取 2 是刻意保守：回放中「只有 1 筆 live 證據」出現過判錯（真的在 A 店那次
-- 只有 1 筆走路途中的點、會被判成 B）。1 筆只在「與 CLVisit 互相印證」時才採信，見下。
insert into public.visit_event_policies
  (version, active, pre_window_s, post_window_s, min_agree_points, min_consensus_points, max_live_accuracy_m)
values (1, true, 120, 300, 1, 2, 100.0)
on conflict (version) do nothing;

-- ── 裁決結果：一段停留一列 ───────────────────────────────────────────────────
create table if not exists public.visit_event_decisions (
  visit_id          bigint primary key references public.visits(id) on delete cascade,
  user_id           uuid        not null references auth.users(id) on delete cascade,
  decision_status   text        not null default 'pending'
                      check (decision_status in ('pending','resolved','unresolved')),
  reason_code       text,
  legacy_would_emit boolean     not null default false,  -- 現行系統會不會對這段發事件（隱私閘）
  landmark_id       bigint,                              -- 刻意不加 FK：地標事後被刪，裁決仍要留存
  name_snapshot     text,                                -- 🔴 存快照：地標事後改名／刪除，離開仍沿用到達當時的名字
  evidence_count    integer     not null default 0,      -- 通過品質過濾、且真的參與投票的 live 點數
  algorithm_version text        not null default 'visit_name_v1',
  policy_version    integer,
  decided_at        timestamptz,
  arrival_sent_at   timestamptz,                         -- 發送冪等鍵：cron 與觸發器不會重播
  departure_sent_at timestamptz,
  created_at        timestamptz not null default now()
);

create index if not exists visit_event_decisions_pending
  on public.visit_event_decisions (decision_status) where decision_status = 'pending';

comment on table public.visit_event_decisions is
  '每段停留的地名裁決結果（只裁決一次，離開沿用）。name_snapshot 刻意存快照而非現算。';

alter table public.visit_event_policies  enable row level security;
alter table public.visit_event_decisions enable row level security;
-- 不建任何 policy：這兩張是內部表，只有 security definer 函式（owner 權限）碰得到。
-- anon / authenticated 一律讀不到，與既有「消費端權限一無所有」的紀律一致。

-- ── 裁決 ─────────────────────────────────────────────────────────────────────
-- 證據＝時窗內的 live 點群。刻意的兩個不對稱：
--   1. live 點解析地標時**不加** accuracy 放寬量；CLVisit 候選沿用舊規則（加自己的 accuracy）。
--      放寬量的方向是「提高召回」，用在證據側會讓爛點也投得出票。
--   2. 時窗上緣夾在 departed_at：人都走了，之後的點不是這段停留的證據。
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
  win_from     timestamptz;
  win_to       timestamptz;
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

  -- 現行系統會不會對這段說話（＝隱私閘，本次不放寬事件涵蓋範圍）
  legacy_name := public.resolve_alias(v.user_id, v.lat, v.lng, coalesce(v.accuracy, 0));

  win_from := v.arrived_at - make_interval(secs => pol.pre_window_s);
  win_to   := least(v.arrived_at + make_interval(secs => pol.post_window_s),
                    coalesce(v.departed_at, 'infinity'::timestamptz));

  -- live 點投票：一個點一票，投給它自己解出來的地標
  with ev as (
    select public.resolve_alias(v.user_id, h.lat, h.lng, 0) as nm
    from public.location_history h
    where h.user_id = v.user_id
      and h.captured_at between win_from and win_to
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
    -- 兩種獨立證據互相印證 → 最強的一種，1 筆就夠
    st := 'resolved'; rc := 'clvisit_live_agree';
    out_name := top_name; out_n := top_n;
  elsif top_name is not null and top_n >= pol.min_consensus_points and named_kinds = 1 then
    -- 純 live 共識。legacy_name 不同時即為「推翻 CLVisit」，正是上述實例要的結果
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
  where t.decision_status = 'pending'          -- 🔴 只裁決一次；已定案的不再被覆寫
  returning * into d;

  if d.visit_id is null then                    -- 上面的 where 擋下 → 已定案，回傳既有那列
    select * into d from public.visit_event_decisions where visit_id = p_visit_id;
  end if;
  return d;
end $$;

comment on function public.adjudicate_visit_place(bigint) is
  '對一段停留裁決地名（live 點群投票；只裁決一次）。回傳 visit_event_decisions 那一列。';

-- ── 發送（冪等）──────────────────────────────────────────────────────────────
-- resolved      → v1 具名事件（既有形狀 ＋ 裁決欄位）
-- unresolved 且 legacy_would_emit → v2 不具名事件（name = null ＋ 原因碼）
-- unresolved 且 not legacy_would_emit → 完全不發（維持「未命中就靜默」）
--
-- 🔴 schema_version 分流是刻意的：現行下游過濾掉 schema_version != 1，因此會**自動略過 v2**，
--    不會因為缺 name 欄而拋例外。下游更新後才看得到 v2。今天完成的是 producer 這一側。
create or replace function public.visit_event_emit(p_visit_id bigint, p_kind text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.visits%rowtype;
  d public.visit_event_decisions%rowtype;
  already timestamptz;
begin
  select * into v from public.visits where id = p_visit_id;
  select * into d from public.visit_event_decisions where visit_id = p_visit_id;
  if not found or v.id is null or d.decision_status = 'pending' then
    return false;
  end if;
  already := case when p_kind = 'arrival' then d.arrival_sent_at else d.departure_sent_at end;
  if already is not null then
    return false;                                  -- 冪等：cron 與觸發器搶同一則時只送一次
  end if;
  if d.decision_status = 'unresolved' and not d.legacy_would_emit then
    return false;                                  -- 隱私閘：現行系統本來就不會對這段說話
  end if;

  perform realtime.send(
    jsonb_build_object(
      'schema_version',    case when d.decision_status = 'resolved' then 1 else 2 end,
      'kind',              p_kind,
      'name',              d.name_snapshot,        -- unresolved 時為 null
      'visit_id',          v.id,
      'arrived_at',        v.arrived_at,
      'departed_at',       v.departed_at,
      'dwell_s',           case when v.departed_at is not null
                                then extract(epoch from (v.departed_at - v.arrived_at))::int end,
      'decision_status',   d.decision_status,
      'reason_code',       d.reason_code,
      'evidence_count',    d.evidence_count,
      'algorithm_version', d.algorithm_version,
      'policy_version',    d.policy_version
    ),
    'visit',
    'wb:events:' || v.user_id::text,
    true
  );

  if p_kind = 'arrival' then
    update public.visit_event_decisions set arrival_sent_at = now() where visit_id = p_visit_id;
  else
    update public.visit_event_decisions set departure_sent_at = now() where visit_id = p_visit_id;
  end if;
  return true;
end $$;

-- ── 觸發器：到達只建候選、不猜名字 ───────────────────────────────────────────
create or replace function public.visit_event_broadcast() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  pol public.visit_event_policies%rowtype;
  d   public.visit_event_decisions%rowtype;
begin
  select * into pol from public.visit_event_policies where active order by version desc limit 1;

  if tg_op = 'INSERT' then
    insert into public.visit_event_decisions (visit_id, user_id) values (new.id, new.user_id)
      on conflict (visit_id) do nothing;
    -- 補傳的停留（事後才落地）已經過了截止點 → 證據都在了，當場裁決、當場發
    if pol.version is not null
       and (now() >= new.arrived_at + make_interval(secs => pol.post_window_s)
            or new.departed_at is not null) then
      d := public.adjudicate_visit_place(new.id);
      perform public.visit_event_emit(new.id, 'arrival');
      if new.departed_at is not null then
        perform public.visit_event_emit(new.id, 'departure');
      end if;
    end if;
    -- 否則留 pending，交給 visit_event_flush()（見下）—— 🔴 不在觸發器裡等
    return new;

  elsif tg_op = 'UPDATE' and old.departed_at is null and new.departed_at is not null then
    -- 人都走了，這段停留的證據不會再多 → 此刻裁決（若還沒裁決過）
    d := public.adjudicate_visit_place(new.id);
    perform public.visit_event_emit(new.id, 'arrival');     -- 補發（若到達那則還沒送出）
    perform public.visit_event_emit(new.id, 'departure');   -- 🔴 沿用同一份裁決，不重新命名
    return new;
  end if;
  return new;
end $$;

comment on function public.visit_event_broadcast() is
  '到達建立待裁決候選；離開時裁決（若未裁決）並依序補發到達／離開。名字一律取裁決快照，不即時重算。';

-- ── 截止點到了就裁決（排程）──────────────────────────────────────────────────
create or replace function public.visit_event_flush()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  pol public.visit_event_policies%rowtype;
  r   record;
  n   integer := 0;
begin
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then return 0; end if;

  for r in
    select d.visit_id from public.visit_event_decisions d
    join public.visits v on v.id = d.visit_id
    where d.decision_status = 'pending'
      and now() >= v.arrived_at + make_interval(secs => pol.post_window_s)
    order by d.visit_id
    for update of d skip locked                 -- 與觸發器搶同一列時直接跳過，不阻塞寫入路徑
  loop
    perform public.adjudicate_visit_place(r.visit_id);
    perform public.visit_event_emit(r.visit_id, 'arrival');
    if exists (select 1 from public.visits where id = r.visit_id and departed_at is not null) then
      perform public.visit_event_emit(r.visit_id, 'departure');
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

comment on function public.visit_event_flush() is
  '把已過裁決截止點的 pending 停留裁決掉並發事件。由 pg_cron 每分鐘呼叫；無 pg_cron 時可手動呼叫。';

revoke all on function public.adjudicate_visit_place(bigint) from public;
revoke all on function public.visit_event_emit(bigint, text) from public;
revoke all on function public.visit_event_flush() from public;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.unschedule('wherebear-visit-event-flush')
      where exists (select 1 from cron.job where jobname = 'wherebear-visit-event-flush');
    perform cron.schedule('wherebear-visit-event-flush', '* * * * *',
                          $cron$ select public.visit_event_flush(); $cron$);
  end if;
end $$;

-- 🔴 刻意不回放歷史 visits：既有的 visits 不會長出 decision 列、也不會補發事件。
--    回放會對下游灌一堆過期事件。本 migration 只影響部署之後產生的新停留。
