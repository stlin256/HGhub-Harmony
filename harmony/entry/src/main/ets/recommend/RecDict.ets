import { JSON } from '@kit.ArkTS';
import { DictEntry, RecRawDict } from './RecTypes';

/**
 * 标签词典：genre_dict.json 的只读封装。
 *
 * - 载入一次，常驻内存（约 200 条词 + aliases，<100 KB）；
 * - 提供上游 tag → 标签 id 的直采映射，以及对标题/简介的最小关键词打标；
 * - 未知标签走动态 id（0xF000 | fnv1a32(tag) & 0x0FFF），与设计文档 §6.2 一致。
 */
export class RecDict {
  private static entries: DictEntry[] = [];
  private static bySurface: Map<string, number> = new Map<string, number>();
  private static synonyms: Map<string, string> = new Map<string, string>();
  private static stopwords: string[] = [];
  private static loaded: boolean = false;
  private static version: string = '';

  static isLoaded(): boolean {
    return RecDict.loaded;
  }

  static dictVersion(): string {
    return RecDict.version;
  }

  /** 解析并建立索引；失败返回 false（推荐降级为仅热度）。 */
  static load(text: string): boolean {
    try {
      const raw = JSON.parse(text) as RecRawDict;
      const entries: DictEntry[] = [];
      const bySurface: Map<string, number> = new Map<string, number>();
      const layers: string[] = ['genre', 'element', 'relation', 'form', 'attribute', 'scene', 'celebrity', 'role', 'source'];
      for (let i = 0; i < layers.length; i++) {
        const list: DictEntry[] | undefined = raw.layers[layers[i]];
        if (list === undefined || list === null) {
          continue;
        }
        for (let j = 0; j < list.length; j++) {
          const entry: DictEntry = list[j];
          entries.push(entry);
          RecDict.addSurface(bySurface, entry.name, entry.id);
          const aliases: string[] = entry.aliases === undefined || entry.aliases === null ? [] : entry.aliases;
          for (let k = 0; k < aliases.length; k++) {
            RecDict.addSurface(bySurface, aliases[k], entry.id);
          }
        }
      }
      RecDict.entries = entries;
      RecDict.bySurface = bySurface;
      RecDict.synonyms = new Map<string, string>();
      const synKeys: string[] = Object.keys(raw.synonyms === undefined || raw.synonyms === null ? {} : raw.synonyms);
      for (let i = 0; i < synKeys.length; i++) {
        const v: string | undefined = raw.synonyms[synKeys[i]];
        if (v !== undefined && v !== null) {
          RecDict.synonyms.set(synKeys[i], v);
        }
      }
      RecDict.stopwords = raw.stopwords === undefined || raw.stopwords === null ? [] : raw.stopwords;
      RecDict.version = raw.version === undefined || raw.version === null ? '' : raw.version;
      RecDict.loaded = entries.length > 0;
      return RecDict.loaded;
    } catch (err) {
      RecDict.loaded = false;
      return false;
    }
  }

  private static addSurface(map: Map<string, number>, raw: string, id: number): void {
    const key: string = raw.trim();
    if (key.length === 0) {
      return;
    }
    if (!map.has(key)) {
      map.set(key, id);
    }
  }

  /** 上游 tag → 标签 id（词典未命中走动态 id）。 */
  static tagId(rawTag: string): number {
    const text: string = rawTag.trim();
    if (text.length === 0) {
      return 0;
    }
    const syn: string | undefined = RecDict.synonyms.get(text);
    const key: string = syn === undefined || syn === null ? text : syn;
    const hit: number | undefined = RecDict.bySurface.get(key);
    if (hit !== undefined && hit !== null) {
      return hit;
    }
    return 0xF000 | (RecDict.fnv1a32(key) & 0x0FFF);
  }

  /** 上游 tags 直采。 */
  static labelsFromTags(tags: string[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < tags.length; i++) {
      const id: number = RecDict.tagId(tags[i]);
      if (id !== 0 && out.indexOf(id) < 0) {
        out.push(id);
      }
    }
    return out;
  }

  /**
   * 最小关键词打标：标题/简介命中词典词条（含 aliases）。
   * 仅对有效词条做子串匹配；上限 6 个，避免长文本噪声。
   */
  static labelsFromText(title: string, desc: string): number[] {
    if (RecDict.entries.length === 0) {
      return [];
    }
    const head: string = RecDict.normalize(title);
    const body: string = RecDict.normalize(desc);
    if (head.length === 0 && body.length === 0) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < RecDict.entries.length && out.length < 6; i++) {
      const entry: DictEntry = RecDict.entries[i];
      const surfaces: string[] = [entry.name].concat(entry.aliases === undefined || entry.aliases === null ? [] : entry.aliases);
      let hit: boolean = false;
      for (let k = 0; k < surfaces.length; k++) {
        const word: string = surfaces[k].trim();
        if (word.length === 0 || RecDict.isStopword(word)) {
          continue;
        }
        if (head.indexOf(word) >= 0 || body.indexOf(word) >= 0) {
          hit = true;
          break;
        }
      }
      if (hit && out.indexOf(entry.id) < 0) {
        out.push(entry.id);
      }
    }
    return out;
  }

  /** 标签名（诊断页展示用；未知 / 动态标签返回 #id）。 */
  static tagName(tag: number): string {
    for (let i = 0; i < RecDict.entries.length; i++) {
      if (RecDict.entries[i].id === tag) {
        return RecDict.entries[i].name;
      }
    }
    return '#' + tag.toString(16);
  }

  private static isStopword(word: string): boolean {
    for (let i = 0; i < RecDict.stopwords.length; i++) {
      if (RecDict.stopwords[i] === word) {
        return true;
      }
    }
    return false;
  }

  static normalize(text: string): string {
    if (text.length === 0) {
      return '';
    }
    let out: string = '';
    const lower: string = text.toLowerCase();
    for (let i = 0; i < lower.length; i++) {
      const code: number = lower.charCodeAt(i);
      // 全角 → 半角（ASCII 区间）
      if (code >= 0xFF01 && code <= 0xFF5E) {
        out += String.fromCharCode(code - 0xFEE0);
      } else if (code === 0x3000) {
        out += ' ';
      } else {
        out += lower.charAt(i);
      }
    }
    return out.replace(/\s+/g, ' ').trim();
  }

  private static fnv1a32(text: string): number {
    let hash: number = 0x811C9DC5;
    for (let i = 0; i < text.length; i++) {
      hash ^= text.charCodeAt(i);
      hash = (hash * 0x01000193) >>> 0;
    }
    return hash >>> 0;
  }
}
