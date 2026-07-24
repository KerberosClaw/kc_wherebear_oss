# supabase/ — 後端（BE）

Supabase-native 後端：SQL + Edge Functions。無自架 server。

```
migrations/   SQL：雙表（current_location + location_history）+ RLS + pg_cron 封存
functions/    Edge Functions（Deno/TS）：
              last-location（讀取口，(c) shared secret）
              reverse-geocode（server 端回填 place_label）
```

- 秘密（`service_role`、geocode key、read shared secret）走 `supabase secrets set`，**不進 repo**。
- 本地開發：`supabase start`（Docker，免帳號）跑整套 stack 做 spike。
- 詳細架構見 [`../docs/DESIGN.md`](../docs/DESIGN.md)。🚧 Phase 1 施工中。
