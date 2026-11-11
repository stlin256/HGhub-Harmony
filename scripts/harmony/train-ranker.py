#!/usr/bin/env python3
"""训练并导出端侧排序模型（两塔 MLP + 显式交互/文本特征，ONNX → MindSpore Lite .ms）。

模型结构（batch 固定 128，user/item 同维 393，便于端侧构造）：
  user 输入 [N, 393] = 256 标签桶亲和 + 2 统计特征 + 7 预留 + 128 文本 3-gram
  item 输入 [N, 393] = 256 标签桶 + 9 质量/类目特征 + 128 文本 3-gram
  两塔各 48 维 → concat 96 → 48 → base 分
  显式交互：prod = user * item（按位），inter = prod @ Wint(393x1)
  logit = base + inter；sigmoid → 点击率
  说明：Wint 可直接表达"标签桶亲和权重"与"文本桶相似度权重"（可理解为学出来的
  IDF/相似度权重），MLP 负责非线性组合；user/item 的标签桶与文本桶位置严格对齐。

训练数据：随包目录（标题/标签/简介/热度/评分）+ 合成用户会话，无云端、无用户数据。
标签生成：对"标签亲和 / 文本相似 / 热度 / 新鲜度 / 评分"做 z-score 后加权 sigmoid 采样，
保证偏好信号强且可学（原始量纲下这些特征的方差很小）；训练/验证按用户切分。
产物：<out-dir>/ranker.onnx（固定 batch=128）
"""
import argparse
import json
import os
import time

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

BUCKETS = 256
ITEM_EXTRA = 9
TEXT_DIM = 128
FEAT_DIM = BUCKETS + ITEM_EXTRA + TEXT_DIM
TEXT_OFF = BUCKETS + ITEM_EXTRA
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


def text_vec(title: str, desc: str) -> np.ndarray:
    """字符 3-gram FNV 哈希到 TEXT_DIM 桶，L2 归一化（与端侧 RecModel 同一口径）。"""
    vec = np.zeros(TEXT_DIM, np.float32)
    text = (title + " " + desc).lower()
    if len(text) < 3:
        return vec
    for i in range(len(text) - 2):
        h = 2166136261
        for k in range(3):
            h ^= ord(text[i + k])
            h = (h * 16777619) & 0xFFFFFFFF
        vec[h % TEXT_DIM] += 1.0
    norm = float(np.sqrt((vec * vec).sum()))
    if norm > 0:
        vec /= norm
    return vec


def load_catalog(path: str):
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    rows = raw.get("items") or []
    item_mat = np.zeros((len(rows), FEAT_DIM), np.float32)
    now = time.time()
    for i, r in enumerate(rows):
        vid, title, cover, labels, pop, cate, eps, score, hot, finished, author, last_ep, desc = r
        labels = [int(t) for t in labels]
        vec = item_mat[i]
        for t in labels:
            vec[bucket_of(t)] += 1.0
        n = max(1, len(labels))
        vec[:BUCKETS] /= n
        vec[BUCKETS + 0] = float(pop)
        fresh = 0.5
        if last_ep:
            age = (now - float(last_ep)) / 86400.0
            fresh = max(0.0, min(1.0, 1.0 - age / 7.0))
        vec[BUCKETS + 1] = fresh
        vec[BUCKETS + 2] = float(score) / 10.0
        vec[BUCKETS + 3] = min(1.0, float(eps) / 100.0)
        vec[BUCKETS + 4] = 1.0 if finished else 0.0
        if 0 <= cate < CATES:
            vec[BUCKETS + 5 + cate] = 1.0
        vec[TEXT_OFF:TEXT_OFF + TEXT_DIM] = text_vec(title, desc or "")
    return item_mat


def make_samples(item_mat: np.ndarray, rng, users: int, items_per_user: int):
    """生成合成用户会话；返回 user/item 特征矩阵与用于造标签的原始量。"""
    XU, XI = [], []
    aff, tsim, pop, fresh, score = [], [], [], [], []
    n_items = item_mat.shape[0]
    for _ in range(users):
        k = int(rng.integers(4, 9))
        anchors = rng.choice(n_items, size=k, replace=False)
        prefs = np.zeros(BUCKETS, np.float32)
        utext = np.zeros(TEXT_DIM, np.float32)
        for idx in anchors:
            prefs += item_mat[idx][:BUCKETS] * float(rng.uniform(0.6, 1.6))
            utext += item_mat[idx][TEXT_OFF:TEXT_OFF + TEXT_DIM] * float(rng.uniform(0.6, 1.6))
        if prefs.sum() > 0:
            prefs /= prefs.sum()
        tnorm = float(np.sqrt((utext * utext).sum()))
        if tnorm > 0:
            utext /= tnorm
        user = np.zeros(FEAT_DIM, np.float32)
        user[:BUCKETS] = prefs
        user[BUCKETS + 0] = 1.0
        user[BUCKETS + 1] = float(k) / 10.0
        user[TEXT_OFF:TEXT_OFF + TEXT_DIM] = utext
        sample_idx = rng.choice(n_items, size=min(items_per_user, n_items), replace=False)
        for idx in sample_idx:
            item = item_mat[idx]
            XU.append(user.copy())
            XI.append(item.copy())
            aff.append(float(np.dot(prefs, item[:BUCKETS])))
            tsim.append(float(np.dot(utext, item[TEXT_OFF:TEXT_OFF + TEXT_DIM])))
            pop.append(float(item[BUCKETS]))
            fresh.append(float(item[BUCKETS + 1]))
            score.append(float(item[BUCKETS + 2]))
    return (np.asarray(XU, np.float32), np.asarray(XI, np.float32),
            np.asarray(aff), np.asarray(tsim), np.asarray(pop), np.asarray(fresh), np.asarray(score))


def make_labels(aff, tsim, pop, fresh, score, rng):
    def z(x):
        return (x - x.mean()) / (x.std() + 1e-9)
    logit = 2.4 * z(aff) + 2.0 * z(tsim) + 0.8 * z(pop) + 0.5 * z(fresh) + 0.4 * z(score)
    prob = 1.0 / (1.0 + np.exp(-logit))
    y = (rng.random(len(prob)) < prob).astype(np.float32).reshape(-1, 1)
    return y


def init_params(rng):
    def w(shape, scale=0.05):
        return (rng.standard_normal(shape) * scale).astype(np.float32)
    return {
        'Wu': w((FEAT_DIM, TOWER)), 'bu': np.zeros(TOWER, np.float32),
        'Wi': w((FEAT_DIM, TOWER)), 'bi': np.zeros(TOWER, np.float32),
        'Wm': w((TOWER * 2, MID)), 'bm': np.zeros(MID, np.float32),
        'Wo': w((MID, 1)), 'bo': np.zeros(1, np.float32),
        'Wint': np.zeros((FEAT_DIM, 1), np.float32),
    }


def forward(p, xu, xi):
    hu = np.maximum(0, xu @ p['Wu'] + p['bu'])
    hi = np.maximum(0, xi @ p['Wi'] + p['bi'])
    h = np.concatenate([hu, hi], axis=1)
    hm = np.maximum(0, h @ p['Wm'] + p['bm'])
    base = hm @ p['Wo'] + p['bo']
    prod = xu * xi
    inter = prod @ p['Wint']
    logit = base + inter
    prob = 1.0 / (1.0 + np.exp(-logit))
    return prob, (xu, xi, hu, hi, h, hm, base, prod, logit, prob)


def train(p, xu, xi, y, epochs=30, batch=256, lr=0.02, rng=None):
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
            prob, (xu_b, xi_b, hu, hi, h, hm, base, prod, logit, pr) = forward(params, xb_u, xb_i)
            total += float(-np.mean(yb * np.log(pr + 1e-7) + (1 - yb) * np.log(1 - pr + 1e-7))) * len(idx)
            dlogit = (pr - yb) / len(idx)
            gWint = prod.T @ dlogit
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
            grads = {'Wu': xu_b.T @ dhu, 'bu': dhu.sum(axis=0),
                     'Wi': xi_b.T @ dhi, 'bi': dhi.sum(axis=0),
                     'Wm': gWm, 'bm': gbm, 'Wo': gWo, 'bo': gbo, 'Wint': gWint}
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
    ys = y[order, 0]
    pos = ys.sum()
    neg = len(ys) - pos
    if pos == 0 or neg == 0:
        return 0.5
    ranks = np.arange(1, len(ys) + 1)
    return float((ranks[ys == 1].sum() - pos * (pos + 1) / 2) / (pos * neg))


def export_onnx(p, path, batch=BATCH):
    def t(name, arr):
        return numpy_helper.from_array(arr.astype(np.float32), name)
    inits = [t('Wu', p['Wu']), t('bu', p['bu']), t('Wi', p['Wi']), t('bi', p['bi']),
             t('Wm', p['Wm']), t('bm', p['bm']), t('Wo', p['Wo']), t('bo', p['bo']),
             t('Wint', p['Wint'])]
    nodes = [
        helper.make_node('MatMul', ['user', 'Wu'], ['hu_mm']),
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
        helper.make_node('Add', ['logit_mm', 'bo'], ['base_logit']),
        helper.make_node('Mul', ['user', 'item'], ['prod']),
        helper.make_node('MatMul', ['prod', 'Wint'], ['inter']),
        helper.make_node('Add', ['base_logit', 'inter'], ['logit_add']),
        helper.make_node('Sigmoid', ['logit_add'], ['logit']),
    ]
    graph = helper.make_graph(
        nodes, 'hghub_ranker',
        [helper.make_tensor_value_info('user', TensorProto.FLOAT, [batch, FEAT_DIM]),
         helper.make_tensor_value_info('item', TensorProto.FLOAT, [batch, FEAT_DIM])],
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
    ap.add_argument('--epochs', type=int, default=35)
    ap.add_argument('--users', type=int, default=120)
    ap.add_argument('--items-per-user', type=int, default=220)
    ap.add_argument('--seed', type=int, default=11)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out_dir, exist_ok=True)
    item_mat = load_catalog(args.catalog)
    print(f'[data] items={item_mat.shape[0]} feat_dim={FEAT_DIM} text_dim={TEXT_DIM}')
    xu, xi, aff, tsim, pop, fresh, score = make_samples(item_mat, rng, args.users, args.items_per_user)
    y = make_labels(aff, tsim, pop, fresh, score, rng)
    print(f'[data] samples={xu.shape[0]} positive={float(y.mean()):.3f}')
    split = int(len(y) * 0.9)
    p = init_params(rng)
    p = train(p, xu[:split], xi[:split], y[:split], epochs=args.epochs, rng=rng)
    prob, _ = forward(p, xu[split:], xi[split:])
    print(f'[eval] val_auc={auc(y[split:], prob):.4f}')
    prob_tr, _ = forward(p, xu[:split], xi[:split])
    print(f'[eval] train_auc={auc(y[:split], prob_tr):.4f}')
    out = os.path.join(args.out_dir, 'ranker.onnx')
    export_onnx(p, out)
    print(f'[ranker] onnx saved: {out} {os.path.getsize(out)} bytes')


if __name__ == '__main__':
    main()
