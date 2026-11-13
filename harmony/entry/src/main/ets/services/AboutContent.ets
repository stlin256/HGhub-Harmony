import { ConfigRegistry } from './ConfigRegistry';
import { I18n } from '../utils/I18n';
import { isSafeWebUrl } from '../utils/Security';

/** 关于页一个内容块：纯文本 / 外链 / 分隔线。 */
export interface AboutBlock {
  kind: string;
  text: string;
  title: string;
  subtitle: string;
  url: string;
}

export interface AboutSection {
  title: string;
  blocks: AboutBlock[];
}

/** 关于页可远程覆盖的完整展示模型；缺省字段回落到内置默认值。 */
export interface AboutView {
  title: string;
  name: string;
  intro: string;
  disclaimerTitle: string;
  disclaimer: string;
  authorName: string;
  authorSubtitle: string;
  authorUrl: string;
  repoTitle: string;
  repoSubtitle: string;
  repoUrl: string;
  license: string;
  showLogo: boolean;
  showVersion: boolean;
  showIntro: boolean;
  showDisclaimer: boolean;
  showAuthor: boolean;
  showRepo: boolean;
  showLicense: boolean;
  sections: AboutSection[];
}

const MAX_TEXT: number = 2000;
const MAX_TITLE: number = 80;
const MAX_LINK_TEXT: number = 120;
const MAX_SECTIONS: number = 20;
const MAX_BLOCKS: number = 50;
const MAX_LINKS: number = 30;

/** 关于页远程内容：缺省/非法字段逐项回落，旧配置完全兼容。 */
export class AboutContent {
  static load(): AboutView {
    const view: AboutView = AboutContent.defaults();
    const raw: Object | null = ConfigRegistry.about();
    if (raw === null || raw === undefined) {
      return view;
    }
    const map: Record<string, Object> = raw as Record<string, Object>;
    view.title = AboutContent.textOf(map, 'title', view.title, MAX_TITLE);
    view.name = AboutContent.textOf(map, 'name', view.name, MAX_TITLE);
    view.intro = AboutContent.textOf(map, 'intro', view.intro, MAX_TEXT);
    view.disclaimerTitle = AboutContent.textOf(map, 'disclaimer_title', view.disclaimerTitle, MAX_TITLE);
    view.disclaimer = AboutContent.textOf(map, 'disclaimer', view.disclaimer, MAX_TEXT);
    view.authorName = AboutContent.textOf(map, 'author_name', view.authorName, MAX_TITLE);
    view.authorSubtitle = AboutContent.textOf(map, 'author_subtitle', view.authorSubtitle, MAX_TITLE);
    view.authorUrl = AboutContent.urlOf(map, 'author_url', view.authorUrl);
    view.repoTitle = AboutContent.textOf(map, 'repo_title', view.repoTitle, MAX_TITLE);
    view.repoSubtitle = AboutContent.textOf(map, 'repo_subtitle', view.repoSubtitle, MAX_TITLE);
    view.repoUrl = AboutContent.urlOf(map, 'repo_url', view.repoUrl);
    view.license = AboutContent.textOf(map, 'license', view.license, MAX_TEXT);
    view.showLogo = AboutContent.boolOf(map, 'show_logo', view.showLogo);
    view.showVersion = AboutContent.boolOf(map, 'show_version', view.showVersion);
    view.showIntro = AboutContent.boolOf(map, 'show_intro', view.showIntro);
    view.showDisclaimer = AboutContent.boolOf(map, 'show_disclaimer', view.showDisclaimer);
    view.showAuthor = AboutContent.boolOf(map, 'show_author', view.showAuthor);
    view.showRepo = AboutContent.boolOf(map, 'show_repo', view.showRepo);
    view.showLicense = AboutContent.boolOf(map, 'show_license', view.showLicense);
    view.sections = AboutContent.sectionsOf(map['sections']);
    return view;
  }

  private static defaults(): AboutView {
    const view: AboutView = {
      title: '关于',
      name: 'HGhub Harmony',
      intro: I18n.fmt0($r('app.string.ui_82ca4338')),
      disclaimerTitle: I18n.fmt0($r('app.string.ui_576374ba')),
      disclaimer: I18n.fmt0($r('app.string.ui_a2552cea')),
      authorName: 'stlin256',
      authorSubtitle: I18n.fmt0($r('app.string.ui_3b8a6e73')),
      authorUrl: 'https://github.com/stlin256',
      repoTitle: '项目仓库',
      repoSubtitle: 'github.com/stlin256/HGhub-Harmony',
      repoUrl: 'https://github.com/stlin256/HGhub-Harmony',
      license: I18n.fmt0($r('app.string.ui_37445711')),
      showLogo: true,
      showVersion: true,
      showIntro: true,
      showDisclaimer: true,
      showAuthor: true,
      showRepo: true,
      showLicense: true,
      sections: []
    };
    return view;
  }

  private static textOf(map: Record<string, Object>, key: string, fallback: string, maxLen: number): string {
    const value: Object | undefined = map[key];
    if (typeof value !== 'string') {
      return fallback;
    }
    const text: string = value.trim();
    return text.length === 0 ? fallback : (text.length > maxLen ? text.substring(0, maxLen) : text);
  }

  private static boolOf(map: Record<string, Object>, key: string, fallback: boolean): boolean {
    const value: Object | undefined = map[key];
    return typeof value === 'boolean' ? value : fallback;
  }

  private static urlOf(map: Record<string, Object>, key: string, fallback: string): string {
    const value: Object | undefined = map[key];
    if (typeof value !== 'string' || !isSafeWebUrl(value)) {
      return fallback;
    }
    return value;
  }

  private static sectionsOf(value: Object | undefined): AboutSection[] {
    const out: AboutSection[] = [];
    if (!Array.isArray(value)) {
      return out;
    }
    const items: Object[] = value as Object[];
    for (let i = 0; i < items.length && out.length < MAX_SECTIONS; i++) {
      const item: Object = items[i];
      if (item === null || item === undefined || typeof item !== 'object' || Array.isArray(item)) {
        continue;
      }
      const map: Record<string, Object> = item as Record<string, Object>;
      const section: AboutSection = {
        title: AboutContent.textOf(map, 'title', '', MAX_TITLE),
        blocks: AboutContent.blocksOf(map['blocks'])
      };
      if (section.blocks.length > 0) {
        out.push(section);
      }
    }
    return out;
  }

  private static blocksOf(value: Object | undefined): AboutBlock[] {
    const out: AboutBlock[] = [];
    if (!Array.isArray(value)) {
      return out;
    }
    const items: Object[] = value as Object[];
    for (let i = 0; i < items.length && out.length < MAX_BLOCKS; i++) {
      const item: Object = items[i];
      if (item === null || item === undefined || typeof item !== 'object' || Array.isArray(item)) {
        continue;
      }
      const map: Record<string, Object> = item as Record<string, Object>;
      const kindValue: Object | undefined = map['type'];
      const kind: string = typeof kindValue === 'string' ? kindValue : 'text';
      if (kind === 'divider') {
        out.push({ kind: 'divider', text: '', title: '', subtitle: '', url: '' });
        continue;
      }
      if (kind === 'link') {
        const url: string = AboutContent.urlOf(map, 'url', '');
        if (url.length === 0) {
          continue;
        }
        out.push({
          kind: 'link',
          text: '',
          title: AboutContent.textOf(map, 'title', '', MAX_LINK_TEXT),
          subtitle: AboutContent.textOf(map, 'subtitle', '', MAX_LINK_TEXT),
          url: url
        });
        continue;
      }
      const text: string = AboutContent.textOf(map, 'text', '', MAX_TEXT);
      if (text.length > 0) {
        out.push({ kind: 'text', text: text, title: '', subtitle: '', url: '' });
      }
    }
    return out;
  }
}
