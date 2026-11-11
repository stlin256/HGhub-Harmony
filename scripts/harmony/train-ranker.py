#!/usr/bin/env python3
"""训练并导出端侧排序模型（两塔 MLP，ONNX → MindSpore Lite .ms）。

模型（研究选型见 docs/harmony/RECSYS-MODEL-RESEARCH.md）：
  user 输入 [N, 258]：256 桶标签亲和（哈希）+ 2 个统计特征
  item 输入 [N, 265]：256 桶标签哈希 + 9 个质量/类目特征
  两塔各 48 维 → concat 96 → 48 → 1 sigmoid（点击率）
  批维 N 为动态维度，端侧一次推理一批候选，避免逐条推理开销。

训练数据：以随包目录 + 合成用户偏好会话做离线训练（无云端、无用户数据）；
真实用户行为在端侧只用于更新画像特征，模型本身离线训练、随包分发。

用法:
  python scripts/harmony/train-ranker.py
  python scripts/harmony/train-ranker.py --epochs 20 --samples 30000
产物:
  <out-dir>/ranker.onnx
"""
import argparse
import json
import os

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

BUCKETS = 256
ITEM_EXTRA = 9
USER_EXTRA = 2
ITEM_DIM = BUCKETS + ITEM_EXTRA
USER_DIM = BUCKETS + USER_EXTRA
BATCH = 128
TOWER = 48
MID = 48
CATES = 4

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_CATALOG = os.path.join(
    ROOT, "harmony", "entry", "src", "main", "resources", "rawfile", "recommend", "catalog_full.json")
DEFAULT_OUT = os.path.join(ROOT, "scripts", "harmony", ".local", "ranker")


def bucket_of(tag: int) -> int:
    return tag % BUCKETS


def load_catalog(path: str):
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    rows = raw.get("items") or []
    item_mat = np.zeros((len(rows), ITEM_DIM), np.float32)
    tag_sets = []
    for i, r in enumerate(rows):
        vid, title, cover, labels, pop, cate, eps, score, hot, finished, author, last_ep = r
        labels = [int(t) for t in labels]
        tag_sets.append(labels)
        vec = item_mat[i]
        for t in labels:
            vec[bucket_of(t)] += 1.0
        n = max(1, len(labels))
        vec[:BUCKETS] /= n
        vec[BUCKETS + 0] = float(pop)
        # 新鲜度归一（last_ep 秒级；无值给 0.5），与端侧同一口径
        fresh = 0.5
        if last_ep:
            import time
            age = (time.time() - float(last_ep)) / 86400.0
            fresh = max(0.0, min(1.0, 1.0 - age / 7.0))
        vec[BUCKETS + 1] = fresh
        vec[BUCKETS + 2] = float(score) / 10.0
        vec[BUCKETS + 3] = min(1.0, float(eps) / 100.0)
        vec[BUCKETS + 4] = 1.0 if finished else 0.0
        if 0 <= cate < CATES:
            vec[BUCKETS + 5 + cate] = 1.0
    return item_mat, tag_sets


def make_sessions(item_mat: np.ndarray, tag_sets, rng, users: int = 80, items_per_user: int = 180):
    """合成会话：随机潜在偏好 → 生成用户向量 + 点击标签。"""
    XU, XI, Y = [], [], []
    n_items = item_mat.shape[0]
    for _ in range(users):
        # 潜在偏好：从目录里挑 4~8 部「喜欢过的剧」，用它们的标签桶均值作为用户向量
        k = int(rng.integers(4, 9))
        anchors = rng.choice(n_items, size=k, replace=False)
        prefs = np.zeros(BUCKETS, np.float32)
        for idx in anchors:
            prefs += item_mat[idx][:BUCKETS] * float(rng.uniform(0.6, 1.6))
        if prefs.sum() > 0:
            prefs /= prefs.sum()
        user = np.zeros(USER_DIM, np.float32)
        user[:BUCKETS] = prefs
        user[BUCKETS + 0] = min(1.0, prefs.sum())
        user[BUCKETS + 1] = float(k) / 10.0
        sample_idx = rng.choice(n_items, size=min(items_per_user, n_items), replace=False)
        for idx in sample_idx:
            item = item_mat[idx]
            # 点击倾向：偏好桶命中（强信号）+ 质量 + 新鲜度 + 小噪声
            aff = float(np.dot(prefs, item[:BUCKETS]))
            logit = 8.0 * aff + 1.0 * float(item[BUCKETS]) + 0.5 * float(item[BUCKETS + 1]) \
                + 0.3 * float(item[BUCKETS + 2]) - 1.6 + rng.normal(0, 0.15)
            p = 1.0 / (1.0 + np.exp(-logit))
            y = 1.0 if rng.random() < p else 0.0
            XU.append(user.copy())
            XI.append(item.copy())
            Y.append(y)
    return np.asarray(XU, np.float32), np.asarray(XI, np.float32), np.asarray(Y, np.float32).reshape(-1, 1)


def init_params(rng):
    def w(shape, scale=0.08):
        return (rng.standard_normal(shape) * scale).astype(np.float32)
    return {
        'Wu': w((USER_DIM, TOWER)),
        'bu': np.zeros(TOWER, np.float32),
        'Wi': w((ITEM_DIM, TOWER)),
        'bi': np.zeros(TOWER, np.float32),
        'Wm': w((TOWER * 2, MID)),
        'bm': np.zeros(MID, np.float32),
        'Wo': w((MID, 1)),
        'bo': np.zeros(1, np.float32),
    }


def forward(p, xu, xi):
    hu = np.maximum(0, xu @ p['Wu'] + p['bu'])
    hi = np.maximum(0, xi @ p['Wi'] + p['bi'])
    h = np.concatenate([hu, hi], axis=1)
    hm = np.maximum(0, h @ p['Wm'] + p['bm'])
    logit = hm @ p['Wo'] + p['bo']
    prob = 1.0 / (1.0 + np.exp(-logit))
    cache = (xu, xi, hu, hi, h, hm, logit, prob)
    return prob, cache


def train(p, xu, xi, y, epochs=25, batch=256, lr=0.02, rng=None):
    n = xu.shape[0]
    params = dict(p)
    m = {k: np.zeros_like(v) for k, v in params.items()}
    v = {k: np.zeros_like(vv) for k, vv in params.items()}
    step = 0
    for ep in range(epochs):
        order = rng.permutation(n)
        total = 0.0
        for s in range(0, n, batch):
            idx = order[s:s + batch]
            xb_u, xb_i, yb = xu[idx], xi[idx], y[idx]
            prob, (xu_b, xi_b, hu, hi, h, hm, logit, pr) = forward(params, xb_u, xb_i)
            loss = float(-np.mean(yb * np.log(pr + 1e-7) + (1 - yb) * np.log(1 - pr + 1e-7)))
            total += loss * len(idx)
            dlogit = (pr - yb) / len(idx)
            gWo = hm.T @ dlogit
            gbo = dlogit.sum(axis=0)
            dhm = dlogit @ params['Wo'].T
            dhm[hm <= 0] = 0
            gWm = h.T @ dhm
            gbm = dhm.sum(axis=0)
            dh = dhm @ params['Wm'].T
            dhu, dhi = dh[:, :TOWER], dh[:, TOWER:]
            dhu[hu <= 0] = 0
            dhi[hi <= 0] = 0
            gWu = xu_b.T @ dhu
            gbu = dhu.sum(axis=0)
            gWi = xi_b.T @ dhi
            gbi = dhi.sum(axis=0)
            grads = {'Wu': gWu, 'bu': gbu, 'Wi': gWi, 'bi': gbi,
                     'Wm': gWm, 'bm': gbm, 'Wo': gWo, 'bo': gbo}
            step += 1
            for k in params:
                m[k] = 0.9 * m[k] + 0.1 * grads[k]
                v[k] = 0.999 * v[k] + 0.001 * (grads[k] ** 2)
                mh = m[k] / (1 - 0.9 ** step)
                vh = v[k] / (1 - 0.999 ** step)
                params[k] -= lr * mh / (np.sqrt(vh) + 1e-8)
        if ep % 5 == 0 or ep == epochs - 1:
            print(f'[train] epoch={ep} loss={total / n:.4f}')
    return params


def auc(y, p):
    order = np.argsort(p[:, 0])
    y_sorted = y[order, 0]
    pos = y_sorted.sum()
    neg = len(y_sorted) - pos
    if pos == 0 or neg == 0:
        return 0.5
    ranks = np.arange(1, len(y_sorted) + 1)
    return float((ranks[y_sorted == 1].sum() - pos * (pos + 1) / 2) / (pos * neg))


def export_onnx(p, path, batch: int = BATCH):
    def t(name, arr):
        return numpy_helper.from_array(arr.astype(np.float32), name)
    nodes, inits = [], []
    inits += [t('Wu', p['Wu']), t('bu', p['bu']), t('Wi', p['Wi']), t('bi', p['bi'])]
    inits += [t('Wm', p['Wm']), t('bm', p['bm']), t('Wo', p['Wo']), t('bo', p['bo'])]
    nodes += [helper.make_node('MatMul', ['user', 'Wu'], ['hu_mm']),
              helper.make_node('Add', ['hu_mm', 'bu'], ['hu_add']),
              helper.make_node('Relu', ['hu_add'], ['hu']),
              helper.make_node('MatMul', ['item', 'Wi'], ['hi_mm']),
              helper.make_node('Add', ['hi_mm', 'bi'], ['hi_add']),
              helper.make_node('Relu', ['hi_add'], ['hi']),
              helper.make_node('Concat', ['hu', 'hi'], ['h'], axis=1),
              helper.make_node('MatMul', ['h', 'Wm'], ['hm_mm']),
              helper.make_node('Add', ['hm_mm', 'bm'], ['hm_add']),
              helper.make_node('Relu', ['hm_add'], ['hm']),
              helper.make_node('MatMul', ['hm', 'Wo'], ['logit_mm']),
              helper.make_node('Add', ['logit_mm', 'bo'], ['logit_add']),
              helper.make_node('Sigmoid', ['logit_add'], ['logit'])]
    graph = helper.make_graph(
        nodes, 'hghub_ranker',
        [helper.make_tensor_value_info('user', TensorProto.FLOAT, [batch, USER_DIM]),
         helper.make_tensor_value_info('item', TensorProto.FLOAT, [batch, ITEM_DIM])],
        [helper.make_tensor_value_info('logit', TensorProto.FLOAT, [batch, 1])],
        initializer=inits)
    model = helper.make_model(graph, producer_name='hghub-recsys',
                              opset_imports=[helper.make_opsetid('', 13)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--catalog', default=DEFAULT_CATALOG)
    ap.add_argument('--out-dir', default=DEFAULT_OUT)
    ap.add_argument('--epochs', type=int, default=25)
    ap.add_argument('--users', type=int, default=80)
    ap.add_argument('--items-per-user', type=int, default=180)
    ap.add_argument('--seed', type=int, default=11)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out_dir, exist_ok=True)

    item_mat, tag_sets = load_catalog(args.catalog)
    print(f'[data] items={item_mat.shape[0]} dims item={ITEM_DIM} user={USER_DIM}')
    xu, xi, y = make_sessions(item_mat, tag_sets, rng, args.users, args.items_per_user)
    print(f'[data] samples={xu.shape[0]} positive={float(y.mean()):.3f}')
    # 简单切分：后 10% 做验证
    split = int(len(y) * 0.9)
    p = init_params(rng)
    p = train(p, xu[:split], xi[:split], y[:split], epochs=args.epochs, rng=rng)
    prob, _ = forward(p, xu[split:], xi[split:])
    print(f'[eval] val_auc={auc(y[split:], prob):.4f}')
    out = os.path.join(args.out_dir, 'ranker.onnx')
    export_onnx(p, out)
    print(f'[ranker] onnx saved: {out} {os.path.getsize(out)} bytes')


if __name__ == '__main__':
    main()
