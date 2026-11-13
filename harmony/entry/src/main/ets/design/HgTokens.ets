/**
 * HGhub 鸿蒙原生设计 token（唯一来源）。
 * 数值来自 docs/harmony/DESIGN.md §2；禁止在页面里散落颜色/字号/间距字面量。
 * 深色为设计基准；所有颜色用 #AARRGGBB。
 *
 * UI 下发（SPEC §14 / C9）：关键颜色与间距优先读远程覆盖
 * （ConfigRegistry.uiColor / uiSize），无下发时返回编译期默认值——行为与未接入时完全一致。
 */

import { ConfigRegistry } from '../services/ConfigRegistry';

/**
 * UI 下发入口显隐 key（SPEC §14.1 ui.entries）。
 * 远程 ui.entries 段按这些 key 下发布尔值；未下发时 entryVisible 返回 true（入口照常展示）。
 */
export class UiEntryKey {
  /** 首页 Hero 推荐位。 */
  static readonly HOME_HERO: string = 'home_hero';
  /** 分类页专题入口。 */
  static readonly CATEGORY_TOPICS: string = 'category_topics';
  /** 我的页关注入口。 */
  static readonly PROFILE_FOLLOW: string = 'profile_follow';
  /** 底部 Tab「分类」。 */
  static readonly TAB_CATEGORY: string = 'tab_category';
  /** 底部 Tab「吃瓜」（当前版本无独立 Tab，预留：吃瓜入口在分类页）。 */
  static readonly TAB_POSTS: string = 'tab_posts';
}

export class HgColor {
  // 中性表面
  static canvas(dark: boolean): string {
    return ConfigRegistry.uiColor('canvas', dark ? '#FF0B0C10' : '#FFF3F4F6');
  }

  static surface1(dark: boolean): string {
    return ConfigRegistry.uiColor('surface1', dark ? '#FF14161B' : '#FFFFFFFF');
  }

  static surface2(dark: boolean): string { return dark ? '#FF1B1D23' : '#FFF7F8FA'; }
  static surface3(dark: boolean): string { return dark ? '#FF24272E' : '#FFEDF0F4'; }
  static surface4(dark: boolean): string { return dark ? '#FF2F333B' : '#FFE2E6EC'; }
  static hairline(dark: boolean): string { return dark ? '#1FFFFFFF' : '#FFDCE0E6'; }
  static borderStrong(dark: boolean): string { return dark ? '#26FFFFFF' : '#FFCBD2DB'; }
  static mask(dark: boolean): string { return dark ? '#99000000' : '#66000000'; }
  static skeletonBase(dark: boolean): string { return dark ? '#FF171A1F' : '#FFEDF0F4'; }
  static skeletonHighlight(dark: boolean): string { return dark ? '#FF20242A' : '#FFF7F8FA'; }
  /** 页面背景（新页面统一入口，与 canvas 同值）。 */
  static pageBackground(dark: boolean): string { return dark ? '#FF0B0C10' : '#FFF3F4F6'; }
  /** 卡片背景（新页面统一入口，与 surface1 同值）。 */
  static cardBackground(dark: boolean): string { return dark ? '#FF14161B' : '#FFFFFFFF'; }

  // 文字与语义
  static textPrimary(dark: boolean): string {
    return ConfigRegistry.uiColor('text_primary', dark ? '#FFF5F6F8' : '#FF15171B');
  }

  static textSecondary(dark: boolean): string {
    return ConfigRegistry.uiColor('text_secondary', dark ? '#FFB6BBC4' : '#FF5A616B');
  }

  static textTertiary(dark: boolean): string { return dark ? '#FF878E99' : '#FF667080'; }
  static textDisabled(dark: boolean): string { return dark ? '#FF5B616B' : '#FFB0B7C1'; }

  static accent(dark: boolean): string {
    return ConfigRegistry.uiColor('accent', dark ? '#FF60CDFF' : '#FF0067C0');
  }

  static accentPressed(dark: boolean): string {
    return ConfigRegistry.uiColor('accent_pressed', dark ? '#FF4CB8E8' : '#FF00559E');
  }
  static onAccent(dark: boolean): string { return dark ? '#FF003042' : '#FFFFFFFF'; }
  static accentSoft(dark: boolean): string { return dark ? '#FF132B36' : '#FFCCE4F7'; }
  static secondaryFill(dark: boolean): string { return dark ? '#FF2A2E36' : '#FFE8EBF0'; }
  static onSecondary(dark: boolean): string { return dark ? '#FFF5F6F8' : '#FF15171B'; }
  static like(dark: boolean): string { return dark ? '#FFFF6F8C' : '#FFE74856'; }
  static star(dark: boolean): string { return dark ? '#FFF3C969' : '#FF9A6B00'; }
  static success(dark: boolean): string { return dark ? '#FF6CCB5F' : '#FF0F7B0F'; }
  static successSurface(dark: boolean): string { return dark ? '#FF173423' : '#FFECF8F0'; }
  static warning(dark: boolean): string { return dark ? '#FFF0B84A' : '#FF8A5A00'; }
  static warningSurface(dark: boolean): string { return dark ? '#FF3C3426' : '#FFFFF7E7'; }
  static danger(dark: boolean): string { return dark ? '#FFFF99A4' : '#FFC42B1C'; }
  static dangerSurface(dark: boolean): string { return dark ? '#FF3B2022' : '#FFFDEEEE'; }
  static onDanger(dark: boolean): string { return dark ? '#FF45060F' : '#FFFFFFFF'; }

  // 视频页专用对比度安全色（不随主题变化）
  static readonly videoInk: string = '#FFFFFFFF';
  static readonly videoInk2: string = '#FFE6E8EC';
  static readonly videoInk3: string = '#FFD5D9DF';
  static readonly videoGold: string = '#FFF3C969';
  static readonly videoLink: string = '#FF8FD0FF';
  static readonly videoChip: string = '#99000000';
  static readonly videoChipStrong: string = '#B3000000';
  static readonly videoHairline: string = '#33FFFFFF';
  static readonly videoScrimFull: string = '#66000000';
  static readonly playerBackground: string = '#FF000000';
  static readonly tabBarDark: string = '#FF0E1013';
  static readonly tabBarLight: string = '#F2FFFFFF';

  // 阴影
  static readonly shadowElev2: string = '#4D000000';
  static readonly shadowElev3: string = '#66000000';
}

export class HgFont {
  static readonly brand: number = 30;
  static readonly pageLarge: number = 28;
  static readonly pageTitle: number = 20;
  static readonly section: number = 17;
  static readonly cardTitle: number = 15;
  static readonly rowTitle: number = 15;
  static readonly body: number = 14;
  static readonly secondary: number = 13;
  static readonly caption: number = 12;
  static readonly micro: number = 11;
  static readonly nano: number = 10;
  static readonly metric: number = 24;
  static readonly playerTitle: number = 16;
  static readonly playerMeta: number = 12;
  static readonly playerTime: number = 12;

  static readonly weightRegular: FontWeight = FontWeight.Regular;
  static readonly weightMedium: FontWeight = FontWeight.Medium;
  static readonly weightBold: FontWeight = FontWeight.Bold;

  static readonly lineBrand: number = 38;
  static readonly linePageLarge: number = 36;
  static readonly linePageTitle: number = 28;
  static readonly lineSection: number = 24;
  static readonly lineCardTitle: number = 21;
  static readonly lineBody: number = 22;
  static readonly lineSecondary: number = 20;
  static readonly lineCaption: number = 18;
  static readonly lineMicro: number = 16;
}

export class HgSpace {
  static readonly xxs: number = 2;
  static readonly xs: number = 4;
  static readonly s: number = 8;
  /** 间距 m（默认 12vp）：远程 ui.sizes.space_m 可覆盖（0-64）。 */
  static get m(): number { return ConfigRegistry.uiSize('space_m', 12); }
  /** 间距 l（默认 16vp）：远程 ui.sizes.space_l 可覆盖（0-64）。 */
  static get l(): number { return ConfigRegistry.uiSize('space_l', 16); }
  /** 间距 xl（默认 20vp）：远程 ui.sizes.space_xl 可覆盖（0-64）。 */
  static get xl(): number { return ConfigRegistry.uiSize('space_xl', 20); }
  static readonly xxl: number = 24;
  static readonly xxxl: number = 28;

  /** 页面左右边距（默认 16vp）：远程 ui.sizes.page_inset 可覆盖（0-64）。 */
  static get pageInset(): number { return ConfigRegistry.uiSize('page_inset', 16); }
  static readonly sheetInset: number = 16;
  static readonly rowInset: number = 16;
  static readonly rowInnerInset: number = 12;
  static readonly cardGap: number = 8;
  static readonly sectionGap: number = 24;
  static readonly controlGap: number = 8;
  static readonly sheetContentGap: number = 12;
  static readonly bottomSafeMin: number = 20;
}

export class HgSize {
  static readonly hitTarget: number = 44;
  static readonly primaryAction: number = 48;
  static readonly secondaryAction: number = 44;
  static readonly control: number = 44;
  static readonly compactControl: number = 36;
  static readonly chipHeight: number = 30;
  static readonly topBar: number = 52;
  static readonly tabBar: number = 56;
  /** 悬浮胶囊底栏占用的垂直空间（含浮动间距），Tab 页滚动内容底部预留用。 */
  static readonly tabBarFloating: number = 68;
  static readonly tabBarLargeFont: number = 64;
  static readonly listRow: number = 52;
  static readonly listRowDouble: number = 64;
  static readonly episodeCell: number = 44;
  static readonly playerRailItem: number = 48;
  static readonly topBarWithSafe: number = 52;
}

export class HgRadius {
  static readonly badge: number = 6;
  /** 内容卡片圆角（新页面统一入口）。 */
  static readonly card: number = 16;
  static readonly inline: number = 8;
  static readonly control: number = 10;
  static readonly row: number = 12;
  static readonly chip: number = 999;
  static readonly group: number = 16;
  static readonly hero: number = 20;
  static readonly surface: number = 24;
  static readonly sheet: number = 28;
}

export class HgIconSize {
  static readonly micro: number = 12;
  static readonly inline: number = 14;
  static readonly compact: number = 16;
  static readonly control: number = 20;
  static readonly emphasis: number = 24;
  static readonly player: number = 26;
  static readonly hero: number = 32;
  static readonly empty: number = 40;
}

export class HgDuration {
  static readonly press: number = 90;
  static readonly micro: number = 140;
  static readonly microExit: number = 120;
  static readonly overlay: number = 190;
  static readonly overlayExit: number = 150;
  static readonly navigation: number = 220;
  static readonly navigationExit: number = 180;
  static readonly surface: number = 260;
  static readonly surfaceExit: number = 220;
  static readonly mask: number = 240;
  static readonly maskExit: number = 200;
  static readonly scrollReturn: number = 280;
  static readonly playerEnter: number = 240;
  static readonly playerExit: number = 200;
  static readonly skeletonFade: number = 220;
  static readonly brand: number = 560;
}
