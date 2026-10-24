#!/usr/bin/env python3
"""
众包词库共识同步引擎

数据文件（GitHub）:
  consensus_state.json  — 投票记录与分类状态（权威数据源）
  shared_vocab.json     — 由 consensus_state.json 自动导出（向后兼容）

用法:
  python consensus_engine.py vote   --word W --category C --user-id U [--base-word B]
  python consensus_engine.py sync   --last-version V
  python consensus_engine.py export-shared-vocab
  python consensus_engine.py migrate-shared-vocab  --file <path_to_shared_vocab.json>
  python consensus_engine.py get-state

约定:
  - 所有分类计算基于 70% 阈值。
  - 判定优先级：超标词 > 拓展词 > 专有词。
  - 课标词（is_curriculum=true）永不参与投票、不可修改。
  - 同一用户对同一词的投票权重恒为1。
  - version 原子递增，每次分类变更 +1。
"""

import argparse
import base64
import json
import sys
import time
import traceback
import urllib.request
import urllib.error

API_BASE = "https://api.github.com/repos/beenhow/ESW/contents"


def _load_token() -> str:
    """从环境变量或本地未入库的 .gh_token 文件读取 PAT，禁止硬编码。"""
    import os
    import pathlib

    for key in ("ESW_GH_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        val = os.environ.get(key, "").strip()
        if val:
            return val
    token_file = pathlib.Path(__file__).with_name(".gh_token")
    if token_file.is_file():
        return token_file.read_text(encoding="utf-8").strip()
    return ""


AUTH_HEADERS = {
    "Authorization": f"Bearer {_load_token()}",
    "Accept": "application/vnd.github.v3+json",
}

VOTE_THRESHOLD = 0.7
CATEGORIES = ["超标词", "拓展词", "专有词"]  # 判定优先级


def _github_get(path: str) -> tuple[dict, str]:
    """GET file from GitHub API. Returns (parsed_json, sha)."""
    url = f"{API_BASE}/{path}"
    req = urllib.request.Request(url, headers=AUTH_HEADERS)
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode())
    content_b64 = data["content"].replace("\n", "").replace("\r", "")
    content_json = json.loads(base64.b64decode(content_b64).decode("utf-8"))
    return content_json, data["sha"]


def _github_put(path: str, content: dict, sha: str, message: str) -> bool:
    """PUT file to GitHub API. Returns True on success."""
    body = {
        "message": message,
        "content": base64.b64encode(
            json.dumps(content, ensure_ascii=False, indent=2).encode("utf-8")
        ).decode(),
        "sha": sha,
    }
    url = f"{API_BASE}/{path}"
    headers = {**AUTH_HEADERS, "Content-Type": "application/json"}
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="PUT",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status in (200, 201)
    except urllib.error.HTTPError as e:
        traceback.print_exc()
        return False


def _reclassify(state: dict) -> dict:
    """根据投票数据重新计算所有词的分类（70%阈值）。

    返回 {changed_words: [{word, old_category, new_category, version}, ...],
           new_state (原地修改后的 state)}
    """
    changed = []
    for word, wdata in state.get("words", {}).items():
        if wdata.get("is_curriculum"):
            # 课标词锁定
            if wdata.get("current_category") != "课标词":
                old = wdata.get("current_category")
                wdata["current_category"] = "课标词"
                state["version"] = state.get("version", 0) + 1
                wdata["classify_version"] = state["version"]
                changed.append({"word": word, "old_category": old, "new_category": "课标词", "version": state["version"]})
            continue

        votes = wdata.get("votes", {})
        if not votes:
            continue

        # 统计各分类票数
        tally = {cat: 0 for cat in CATEGORIES}
        for uid, v in votes.items():
            cat = v.get("category", "")
            if cat in tally:
                tally[cat] += 1

        total = sum(tally.values())
        if total == 0:
            continue

        # 按优先级检查阈值
        new_cat = None
        for cat in CATEGORIES:
            if tally[cat] / total >= VOTE_THRESHOLD:
                new_cat = cat
                break

        if new_cat is None:
            # 无分类达标，保持历史或未定
            new_cat = wdata.get("current_category")

        old_cat = wdata.get("current_category")
        if new_cat and new_cat != old_cat:
            state["version"] = state.get("version", 0) + 1
            wdata["current_category"] = new_cat
            wdata["classify_version"] = state["version"]
            changed.append({"word": word, "old_category": old_cat, "new_category": new_cat, "version": state["version"]})

    return changed


def cmd_vote(args):
    """投票：记录用户分类投票，计算共识并返回当前分类。"""
    word_lower = args.word.lower()
    category = args.category
    user_id = args.user_id

    if category not in CATEGORIES:
        print(json.dumps({"success": False, "error": f"无效分类: {category}，可选: {CATEGORIES}"}, ensure_ascii=False))
        sys.exit(1)

    # 1. 拉取当前状态
    state, sha = _github_get("consensus_state.json")
    words = state.setdefault("words", {})

    # 2. 获取或创建词条
    wdata = words.get(word_lower)
    if wdata is None:
        wdata = {
            "is_curriculum": False,
            "current_category": None,
            "classify_version": 0,
            "votes": {},
            "original_case": args.word,
        }
        words[word_lower] = wdata

    # 3. 课标词检查
    if wdata.get("is_curriculum"):
        print(json.dumps({
            "success": False,
            "error_code": "CURRICULUM_LOCKED",
            "word": args.word,
            "current_category": "课标词",
            "server_version": state.get("version", 0),
            "message": f"「{args.word}」为课标词，不可修改",
        }, ensure_ascii=False))
        return

    # 4. 投票（同用户修改：移除旧分类，加入新分类）
    old_vote = wdata["votes"].get(user_id)
    old_cat = old_vote["category"] if old_vote else None
    wdata["votes"][user_id] = {
        "category": category,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
    }

    # 5. 处理 extendBaseMap
    if hasattr(args, "base_word") and args.base_word:
        ebm = state.setdefault("extendBaseMap", {})
        ebm[args.word] = args.base_word

    # 6. 重新计算分类
    _reclassify(state)

    # 7. 推送
    if not _github_put("consensus_state.json", state, sha, f"vote: {args.word} -> {category} by {user_id}"):
        print(json.dumps({"success": False, "error": "推送GitHub失败（可能发生并发冲突）"}, ensure_ascii=False))
        return

    # 8. 返回结果
    final_cat = wdata["current_category"]
    print(json.dumps({
        "success": True,
        "word": args.word,
        "current_category": final_cat,
        "server_version": state["version"],
        "message": f"「{args.word}」分类为「{final_cat}」" if final_cat else f"「{args.word}」已投票，等待共识（当前无分类）",
    }, ensure_ascii=False))


def cmd_sync(args):
    """增量同步：返回 version > last_version 的所有变更。"""
    last_version = int(args.last_version)

    state, _ = _github_get("consensus_state.json")
    server_version = state.get("version", 0)

    changes = []
    for word, wdata in state.get("words", {}).items():
        cv = wdata.get("classify_version", 0)
        if cv > last_version and wdata.get("current_category"):
            changes.append({
                "word": wdata.get("original_case", word),
                "category": wdata["current_category"],
                "version": cv,
                "is_curriculum": wdata.get("is_curriculum", False),
            })

    # 附加 extendBaseMap 变更（简化：全量返回）
    ebm = state.get("extendBaseMap", {})

    print(json.dumps({
        "success": True,
        "server_version": server_version,
        "last_version": last_version,
        "changes": changes,
        "extendBaseMap": ebm,
    }, ensure_ascii=False))


def cmd_get_state(args):
    """获取当前完整状态（调试用）。"""
    state, sha = _github_get("consensus_state.json")
    print(json.dumps({"success": True, "sha": sha, "state": state}, ensure_ascii=False))


def cmd_export_shared_vocab(args):
    """从 consensus_state.json 导出 shared_vocab.json（向后兼容）。"""
    state, _ = _github_get("consensus_state.json")

    extend_words = []
    chao_gang = []
    extra = []
    ebm = dict(state.get("extendBaseMap", {}))

    for word, wdata in state.get("words", {}).items():
        cat = wdata.get("current_category")
        orig = wdata.get("original_case", word)
        if cat == "拓展词":
            extend_words.append(orig)
        elif cat == "超标词":
            chao_gang.append(orig)
        elif cat == "专有词":
            extra.append(orig)

    result = {
        "extendWords": extend_words,
        "extendBaseMap": ebm,
        "manualChaoGangWords": chao_gang,
        "manualExtraWords": extra,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


def cmd_migrate(args):
    """从旧 shared_vocab.json 迁移到 consensus_state.json（仅初始化使用）。"""
    with open(args.file, "r", encoding="utf-16") as f:
        old = json.load(f)

    state = {"version": 0, "words": {}, "extendBaseMap": {}}
    default_user = "migration_user"

    for word in old.get("extendWords", []):
        w = word.lower()
        state["words"][w] = {
            "is_curriculum": False,
            "current_category": "拓展词",
            "classify_version": 0,
            "original_case": word,
            "votes": {default_user: {"category": "拓展词", "timestamp": "2026-08-01T00:00:00"}},
        }

    for word in old.get("manualChaoGangWords", []):
        w = word.lower()
        if w in state["words"]:
            state["words"][w]["current_category"] = "超标词"
            state["words"][w]["votes"][default_user] = {"category": "超标词", "timestamp": "2026-08-01T00:00:00"}
        else:
            state["words"][w] = {
                "is_curriculum": False,
                "current_category": "超标词",
                "classify_version": 0,
                "original_case": word,
                "votes": {default_user: {"category": "超标词", "timestamp": "2026-08-01T00:00:00"}},
            }

    for word in old.get("manualExtraWords", []):
        w = word.lower()
        if w in state["words"]:
            state["words"][w]["current_category"] = "专有词"
            state["words"][w]["votes"][default_user] = {"category": "专有词", "timestamp": "2026-08-01T00:00:00"}
        else:
            state["words"][w] = {
                "is_curriculum": False,
                "current_category": "专有词",
                "classify_version": 0,
                "original_case": word,
                "votes": {default_user: {"category": "专有词", "timestamp": "2026-08-01T00:00:00"}},
            }

    state["extendBaseMap"] = dict(old.get("extendBaseMap", {}))
    state["version"] = 1

    out_path = args.file.replace("shared_vocab", "consensus_state")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=2)
    print(f"已生成 {out_path}")
    print(f"词条数: {len(state['words'])}, version: {state['version']}")


def main():
    parser = argparse.ArgumentParser(description="众包词库共识同步引擎")
    sub = parser.add_subparsers(dest="cmd")

    p_vote = sub.add_parser("vote")
    p_vote.add_argument("--word", required=True)
    p_vote.add_argument("--category", required=True, choices=CATEGORIES)
    p_vote.add_argument("--user-id", required=True)
    p_vote.add_argument("--base-word", default=None)

    p_sync = sub.add_parser("sync")
    p_sync.add_argument("--last-version", required=True, type=int)

    sub.add_parser("get-state")
    sub.add_parser("export-shared-vocab")

    p_migrate = sub.add_parser("migrate-shared-vocab")
    p_migrate.add_argument("--file", required=True)

    args = parser.parse_args()

    if args.cmd == "vote":
        cmd_vote(args)
    elif args.cmd == "sync":
        cmd_sync(args)
    elif args.cmd == "get-state":
        cmd_get_state(args)
    elif args.cmd == "export-shared-vocab":
        cmd_export_shared_vocab(args)
    elif args.cmd == "migrate-shared-vocab":
        cmd_migrate(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
