-- kc_wherebear — 撤掉 realtime_send_strict 的 PUBLIC 執行權（安全修補）
--
-- 🔴 20260728000003 建了 `realtime_send_strict(jsonb,text,text)`，它是 SECURITY DEFINER
-- 且可指定**任意 payload / 任意 topic**，但漏了撤權 —— PostgreSQL 對新函式預設 grant
-- EXECUTE 給 PUBLIC，所以 anon / authenticated 都叫得動。
--
-- 後果：anon key 本來就公開在 app 內，任何拿到它的人都能對任意使用者的事件頻道
-- （`wb:events:<user_id>`）注入偽造事件 —— 下游消費者無法分辨真假。
--
-- 同一批的 `visit_evidence_window` 有正確撤權（只有 postgres / service_role），
-- 是這一支漏掉。屬於實作疏漏，不是設計問題。
--
-- 修法：撤到底，不重新 grant。
-- 它只被同 schema 內的 SECURITY DEFINER 函式呼叫（visit_event_emit、
-- visits_emit_coverage_ended），那些函式以 owner 身分執行 → 權限檢查看的是 owner，
-- 不需要呼叫端持有 EXECUTE。實測：撤權後既有事件路徑照常運作。
--
-- 🔴 `is_visits_endpoint` 刻意**不撤**：`set_departure_provenance` 是 SECURITY INVOKER
-- （必須如此，否則 current_user 會變成 owner、來源判定全部失準），所以它呼叫這支時是用
-- **真實呼叫者**的權限檢查 —— 撤掉會讓 app 的每一次寫入直接噴
-- 「permission denied for function is_visits_endpoint」。實測確認過。
-- 它不是 SECURITY DEFINER、只做字串比對、不碰任何資料，開著沒有危害。

revoke all on function public.realtime_send_strict(jsonb, text, text) from public;
revoke all on function public.realtime_send_strict(jsonb, text, text) from anon, authenticated;

comment on function public.realtime_send_strict(jsonb,text,text) is
  '與 realtime.send 相同，但**不吞例外** —— 送出失敗必須讓整個交易回滾，否則「已送出」旗標會被錯誤保留。🔴 無任何角色持有 EXECUTE：只允許同 schema 的 SECURITY DEFINER 函式以 owner 身分呼叫。';
