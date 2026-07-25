-- kc_wherebear — visits 補 updated_at
--
-- 為什麼現在補（20260724000001 當時還註明「visits 無 updated_at 欄 → 不需要」）：
-- CLVisit 同一次停留投遞兩次——到達 INSERT、離開 UPDATE（見 D14）。沒有 updated_at
-- 就量不到「iOS 判定離開之後，多久才寫進 DB」這個延遲：2026-07-25 只能靠 D14 修鍵前
-- 遺留的重複列側面推估（結果 0–3 分鐘）。補上之後可以直接量。
--
-- 另一個用途：到達/離開事件通道的時間錨。離開事件由 UPDATE 觸發，下游要判斷事件新鮮度
-- （離線佇列補傳會送出幾小時前的到達），需要知道「這一列最後一次被寫入」是什麼時候。
--
-- 舊列回填 created_at：那是**下限**而非真值——被 UPDATE 過的列，實際最後寫入時間晚於
-- created_at，但沒有紀錄。回填成建立時間比塞 now()（謊報成剛剛更新）誠實。

alter table public.visits add column if not exists updated_at timestamptz;

update public.visits set updated_at = created_at where updated_at is null;

alter table public.visits alter column updated_at set default now();
alter table public.visits alter column updated_at set not null;

drop trigger if exists set_updated_at on public.visits;
create trigger set_updated_at
  before update on public.visits
  for each row execute function extensions.moddatetime(updated_at);

comment on column public.visits.updated_at is
  '最後一次寫入時刻（moddatetime trigger 維護）。到達＝與 created_at 相同；離開投遞會把它推到離開送達的時刻。本 migration 之前的列回填為 created_at，僅為下限。';
