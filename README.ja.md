# asterism-chat

Family mruby の端末のためのチャットホスト ([Asterism](https://github.com/ruby-asterism/asterism) の上で動く)。
設定に書いた部屋を持ち、部屋ごとに発言へ番号を振り、新しい発言を端末に知らせ、部屋ごとの直近の発言をディスクに残す。
後から開いた端末は、見ていなかった分を読める。端末は信頼できるメンバーの Asterism の網の中のもので、どの端末が
入れるかはルータのロール (素の TCP のルータなら設定の `devices`) で決める。

状態: 0.2.0。文字とスタンプ (利用者が描いた小さな絵)。サーバで Asterism の console の隣にコンテナで置ける
([docs/install.md](docs/install.md)、英語)。

## 動かす

```
bundle install
bundle exec exe/asterism-chat --router tcp/127.0.0.1:7447 --node chat
bundle exec exe/asterism-chat status        # 0: 動いていて room を公開している
```

Asterism の console の証明書 (mTLS のルータ) を使うときは、設定に `credentials = "chat.tar"`
(ルータは証明書のものになる)。

SIGTERM (と Ctrl-C): 新しい発言を `stopping` で断り、状態のファイルにそう書いて終わる。

## 設定

コマンドの引数 > 環境変数 > ファイル (`--config` か `ASTERISM_CHAT_CONFIG`) > 既定 の順。全部のキーは
`config/chat.toml.example`、環境変数の一覧は README.md の「Settings」。部屋は `[[rooms]]` の表 (`id`・`title`)
か `ASTERISM_CHAT_ROOMS=id:題,id2:題2`。

## 網の上の形

アプリ `chat`、オブジェクト `room` (`hello`・`rooms`・`post`・`history`・`stamp_has`・`stamp_put`・`stamp_get`)、
トピック `news` (`{"room" => 部屋, "n" => 番号}`、本文は載せない)。形の詳細と誤りの種類の表は README.md の「On the network」。
断るときは例外でなく `{"error" => 種類, "message" => 端末に出す文}` を返す。

スタンプは 48x48 以下・8 KB 以下の PNG で、中身の sha256 で呼ぶ。端末は `post({"room", "stamp" => sha})` を送り、
`no_stamp` なら `stamp_put({"sha", "png"})` で絵を置いてから送り直す。持っていない絵は `stamp_get({"sha"})` で取る。
絵は MessagePack の str でも bin でも受ける (返すのは既定で str、`stamps.binary` か `"as"` で bin)。
ホストが持つ絵は 2,000 枚・16 MB まで (超えたら、どの発言からも指されていない絵から古い順に捨てる)、
1 端末が 1 日に置ける新しい絵は 30 枚 (設定で変えられる)。

## ディスク

`state_dir` の下に `rooms/<id>.jsonl` (残している発言)、`names.json` (ノード名 => 表示名)、`stamps/<sha256>.png`
(スタンプの絵)、`status.json`。`log_dir` の下に 1 日 1 つの JSONL の記録 (発言は部屋・番号・長さかスタンプの sha だけ、
絵は sha・大きさ・端末だけで、本文も絵の中身も入れない)。

## サーバに置く

`deploy/vps/` (Dockerfile・compose・env.example・update.sh) で、Asterism の console の隣にコンテナとして置く。
console に役割 2 つ (`chat-host`: ホスト自身、`chat`: 使う端末) を作り、ホストの証明書 `chat.tar` を
`deploy/vps/credentials/` に置いて `./update.sh <版>` (自分で作るなら `--build`)。手順は docs/install.md。

## 試験

`bundle exec rake test`: 部品の試験と、ローカルの zenohd (docker の `eclipse/zenoh:1.10.2`、127.0.0.1:17530。
タスクが起こして止める) を使う通しの試験。`test/sender.rb` は端末の代わりで、手でも使える。

## ライセンス

MIT
