# wp-migrate lessons(案件ごとの実測記録)

## パイロット案件(2026-07, WP 4.9.8 の中古車販売サイト)

- **WXR に XML 1.0 不正制御文字(U+0008)が実在**(WP 4.9.8)。kit の sanitize が処理するが、他ツールに WXR を渡す時は注意
- **SCF の smart-cf-setting は PHP serialize でバイト長ベース**。日本語を含むと JS 文字列では unserialize に失敗する → kit は Buffer 渡しで解決済み。fast-xml-parser は CDATA 内 CRLF を LF に正規化するため、kit は CDATA を生抽出している
- **SCF 画像フィールドの値は attachment の wp_id**(URL ではない)。`type: "image"` で kit が解決する
- **relation の「未設定」は値 "0"**。kit がスキップする(unresolved 扱いにしない)
- publish 件数には SCF 定義投稿(14件)が含まれる。実公開数は census で `smart-custom-fields` を除いて数える
- URL は post_type から導出不可: about-rovermini が /usedcar/ 配下(末尾スラッシュ混在)、news が /news/YYYY/MM/{id}、custom_permalink 49件 → ルート台帳方式が正解だった
- 価格 meta(total_price)は**万円単位の小数**("87", "134.2")。円換算は表示側の仕事
- タクソノミーアーカイブ(/series/x, /cartype/x)への本文内リンクが25件 → 再現するかは案件ごとの製品判断
- 現行サイトは formrun 使用(form.run/api/v1/r/... へ直接 POST)。フォーム移行は同 endpoint への POST 再現で足りる
- 営業日カレンダーは Google Calendar iframe 埋め込み → そのまま再現可
- microCMS 制限(2026-07 原典確認): Hobby 5 API/Team 10 API、WRITE 5回/秒、1コンテンツ約200KB、POST/PUT 約300KB、GET 60回/秒、Management API 10回/10秒
- microCMS スキーマ JSON は 2026-07-07 に形式変更(customFieldIds 方式)。参照先(relation)はインポートで復元されず手動設定
- Codex sandbox は `listen()` 禁止 → ローカル HTTP サーバーを使うテストは委任先で実行できない。**司令塔が必ずローカルでフルテストを回す**(archive のフォーム二重帰属バグはこれで検出)
- **ページ限定 CSS の見落としに注意**: 実案件では特定の詳細テンプレートだけが読む専用 CSS があった。テンプレ実装前に archive 全ページの `link[rel=stylesheet]` を集計して CSS 回収リストを作ること(トップページの head だけから作らない)
- **Next.js 出力の文字列カウントは RSC ペイロードで2倍に見える**。構造一致の検証は substring 数でなく DOM タグ実体(`<section class="...">` の正規表現)で数える
- サニタイザ(sanitize-html)はデフォルト許可タグが狭く `section`/`div` を剥がす。kit テンプレの legacy-html は「危険物のみ除去」方針に拡張済み(2026-07-13)
- **archive のスクショ段階がハングしうる**(実測: 506/672 で停止、chromium 16プロセス残留)。kit 改善候補: ページ単位の screenshot timeout と失敗スキップ。また画像 URL への直リンクをページとしてクロールしてしまう(除外パターンに拡張子を追加すべき)
- **jQuery プラグイン(imgLiquid / slick)が担っていたレイアウトは CSS で代替**: `.imgLqd > img` に object-fit:cover、カルーセルは scroll-snap。原文が JS 実行後に成立させていた見た目は静的 HTML では出ないので、追加 CSS ファイルで補正する(テーマ CSS は編集しない)
- **float レイアウトの clear 漏れに注意**: 原文で間に挟まっていたセクションを省くと、後続ブロックが float に回り込む(実測: sub-used が価格サイドバーの脇に縦書きで潰れた)。DOM 順一致だけでなく実画面確認が必須
