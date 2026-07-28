-- kc_wherebear — 停留清單的地名改與事件裁決同源（同一段停留不再出現兩個名字）
--
-- ── 要修的問題 ──
-- 20260727000004 讓「事件」的地名改由裁決產生（時窗內 live 點投票、只裁一次、存快照），
-- 但「停留清單」那條路沒有跟著改：它的名字仍是每次查詢當場用 `visits` 那一列的座標現算。
-- 而 iOS 的 CLVisit 到達與離開會各報一組座標、且同一 arrived_at 走 merge-upsert
-- → 到達寫入的粗座標會在離開時被覆寫（D14 已記載實測漂移 33～205 公尺）。
--
-- 結果就是同一段停留、兩個消費端不同名字。實例（實測，兩個地標相距 190 公尺；時刻為相對位移）：
--   T+0m00s   到達，CLVisit 自報座標偏移約 130 公尺 → 落在半徑 60 的另一個地標圈內
--             停留清單顯示那個較小的地標                          ❌
--   T+0m40s ~ T+5m27s  四筆 live 點進來，全部指向正確的地標
--   T+5m48s   裁決：live 共識推翻 CLVisit（reason_code=live_consensus_override）
--             事件發出正確的名字                                   ✅
--   T+13m32s  離開回呼把座標覆寫成較準的一組 → 停留清單這才自己變對 ✅
--   → 錯誤存在 13 分 32 秒。DB 在 T+13m32s 就一致了，「過了很久才好」是觀測錯覺。
--
-- ── 改法 ──
-- 停留清單的名字改成三段式，優先序是「已定案 > 當場重算 > 現行」：
--   ① 該段已有 resolved 裁決 → 直接用 name_snapshot（名字只決定一次，不再隨座標飄）
--   ② 還沒裁決 → 用 visit_place_vote() 當場投票（與 adjudicate_visit_place 同一套規則、但唯讀）
--   ③ 投不出來 → 才退回現行的 resolve_name(CLVisit 座標)
-- ①②共用同一套判準，是「同一個系統只有一套真相」的具體落實；③保證不會比現在差。
--
-- ── 為什麼不是只做①（只吃快照）──
-- 只做①的成本幾乎一樣（同樣得把 visit_id 從 visits_for_day 接出來），但錯誤窗只從
-- 13 分 32 秒縮到 5 分 48 秒（要等政策窗 +300 秒）；加上②可縮到 3 分 24 秒（等第 2 筆 live 點，
-- min_consensus_points=2）。而且只做①在歷史資料上幾乎看不出差別 —— 它的好處全在「事件已發出、
-- 但時間軸還沒被覆寫」的那段窗內，而歷史資料的那段窗早就過去了。
--
-- ── 驗證方式（建議照做）──
-- 先把既有資料重放一次、確認改動前後**逐段相同**，再看差異；否則分不出「修好了」與「弄壞了」。
--   * 回溯差異應該極少，且方向必須是「通用路名 → 使用者自己命名過的地標」。出現反向就是退化。
--   * 效能：多一次唯讀投票，數量級仍在毫秒內；讀取端是低頻輪詢，實務上無感。
--   * 波及面：visits_for_day 只有 stays_for_day 一個呼叫端 —— 改它的回傳型別前請自行再確認一次。
--   * 輸出契約不變 → 不需要動 app、bridge 或手機。
--
-- ── 這支解決不了的 ──
-- 裝置沉默期間，證據窗內可能一個合格 live 點都沒有 → 仍然只能吃 CLVisit 粗座標。
-- 那是取樣密度的物理限制，不是本支能處理的範圍；要根治得處理「離開覆寫到達座標」本身。
-- ⚠️ 反直覺、之後動那題前要記得：**停掉覆寫反而可能讓這類實例永遠顯示錯的名字** ——
-- 離開時回報的那組座標通常比到達時那組準，現況是覆寫救了它。
--
-- ── 刻意不做 ──
-- 不把 visit_id 加進 stays_for_day 的回傳（那會改到讀取口的輸出契約）。
-- 代價是消費端仍無法確定「清單這一列＝哪一段停留」，只能靠時間與座標比對；留作獨立議題。

-- ── 1. visits_for_day：帶出 visit_id（回傳型別變了 → 必須先 drop）──
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
           public.visit_open_until(p_user, v.arrived_at, p_open_grace_s) as capped_at
    from public.visits v
    where v.user_id = p_user
  )
  select x.id,
         greatest(x.arrived_at, b.day_start),
         case
           when x.departed_at is not null then least(x.departed_at, b.day_end)
           -- 寬限用完 → 不再宣稱人還在那裡，給一個具體的結束時刻（而非 null）
           when x.capped_at <= now()      then least(x.capped_at, b.day_end)
           when b.day_end <= now()        then b.day_end
           else null
         end,
         greatest(0, extract(epoch from (
           least(coalesce(x.departed_at, least(now(), x.capped_at)), b.day_end)
           - greatest(x.arrived_at, b.day_start)
         )))::integer,
         x.lat, x.lng, 1.0::double precision, x.accuracy
  from x, b
  where x.arrived_at < b.day_end
    -- 封頂之後這條就不再成立 → 那列自然從往後的每一天消失（原本會永遠出現）
    and coalesce(x.departed_at, least(now(), x.capped_at)) >= b.day_start
$$;

comment on function public.visits_for_day(uuid,date,text,integer) is
  'CLVisit dwells intersecting a local day, clamped to that day；未關閉者以 visit_open_until 封頂。帶出 visit_id 供停留清單取用裁決結果。service_role only.';

revoke all on function public.visits_for_day(uuid,date,text,integer) from public;
grant execute on function public.visits_for_day(uuid,date,text,integer) to authenticated, service_role;

-- ── 2. visit_place_vote：唯讀投票 ──
-- 與 adjudicate_visit_place 同一套規則與同一張 policy，差別只有「不寫任何表」。
-- 🔴 這裡刻意複製、而非抽共用函式再讓裁決呼叫：裁決那支是已經對外發出過事件的路徑，
--    改寫它的風險高於重複一次。先讓讀取側對齊；兩邊規則若日後要改，必須同時改。
--    （後續的 20260728000003 已把證據窗抽成單一定義，解掉這份重複。）
create or replace function public.visit_place_vote(p_visit_id bigint)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v           public.visits%rowtype;
  pol         public.visit_event_policies%rowtype;
  legacy_name text;
  win_from    timestamptz;
  win_to      timestamptz;
  top_name    text;
  top_n       integer := 0;
  named_kinds integer := 0;
begin
  select * into v from public.visits where id = p_visit_id;
  if not found then return null; end if;
  select * into pol from public.visit_event_policies where active order by version desc limit 1;
  if not found then return null; end if;

  legacy_name := public.resolve_alias(v.user_id, v.lat, v.lng, coalesce(v.accuracy, 0));

  win_from := v.arrived_at - make_interval(secs => pol.pre_window_s);
  win_to   := least(v.arrived_at + make_interval(secs => pol.post_window_s),
                    coalesce(v.departed_at, 'infinity'::timestamptz));

  -- live 點投票：一個點一票；證據側不加 accuracy 放寬量（放寬是為提高召回，用在證據側會讓爛點也投得出票）
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
    return top_name;                       -- 兩種獨立證據互相印證
  elsif top_name is not null and top_n >= pol.min_consensus_points and named_kinds = 1 then
    return top_name;                       -- 純 live 共識（不同於 legacy 時即為推翻 CLVisit）
  else
    return null;                           -- 證據不足或互相打架 → 交回呼叫端退回現行做法
  end if;
end $$;

comment on function public.visit_place_vote(bigint) is
  '一段停留的地名投票結果（時窗內 live 點共識，規則與 adjudicate_visit_place 相同但唯讀、不寫決策表）。判不出來回 null。';

revoke all on function public.visit_place_vote(bigint) from public;
grant execute on function public.visit_place_vote(bigint) to service_role;

-- ── 3. stays_for_day：名字改三段式（其餘邏輯一字未改）──
-- 簽章與回傳型別皆不變 → 用 create or replace，不必 drop。
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
    from pair
    order by vid, overlap_s desc, s_dwell desc, sid asc   -- sid 是最後的定序保險，避免同分時非決定性
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
  -- 核心窗：群集時間窗內、且距合併中心 p_core_radius_m 以內的 live 點首末。
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
           greatest(
             least(c.v_from, coalesce(c.c_from, c.v_from)),
             coalesce(c.prev_to, '-infinity'::timestamptz)
           ) as u_from,
           case when c.v_to is null then null
                else least(
                       greatest(c.v_to, coalesce(c.c_to, c.v_to)),
                       coalesce(c.next_from, 'infinity'::timestamptz)
                     )
           end as u_to
    from core c
  )
  -- 🔴 名字：已定案的裁決 > 當場投票 > 現行的座標現算
  select coalesce(
           (select d.name_snapshot from public.visit_event_decisions d
             where d.visit_id = m.visit_id and d.user_id = p_user
               and d.decision_status = 'resolved'),
           public.visit_place_vote(m.visit_id),
           public.resolve_name(p_user, m.lat, m.lng, m.slack)
         ) as name,
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
  union all
  -- 未配對的 live 聚合段：沒有對應的 CLVisit → 沒有裁決可用，維持原樣
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
  '某當地日的合併停留清單：時間取「核心窗聯集」、位置用 live 中心；地名優先序＝已定案的裁決快照 > 當場 live 投票 > CLVisit 座標現算（與事件同源，避免同一段停留兩個名字）。';

revoke all on function public.stays_for_day(uuid,date,text,double precision,double precision) from public;
grant execute on function public.stays_for_day(uuid,date,text,double precision,double precision) to service_role;
