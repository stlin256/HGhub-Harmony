import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import Feed from "../src/components/Feed";
import { AppProvider } from "../src/store";
import { api } from "../src/api";
import "../src/index.css";

// 仅将自定义媒体协议映射到本地测试服务器；播放器、HLS 和鼠标事件均使用真实实现。
const proxy = new URLSearchParams(location.search).get("proxy") || "http://127.0.0.1:17779";
const open = XMLHttpRequest.prototype.open;
XMLHttpRequest.prototype.open = function (this: XMLHttpRequest, method: string, target: string | URL, async: boolean = true, user?: string | null, credential?: string | null) {
  const url = new URL(String(target), location.href);
  if (url.hostname === "hg.localhost" || (url.hostname === "localhost" && url.protocol === "hg:")) {
    target = `${proxy}${url.pathname}${url.search}`;
  }
  return open.call(this, method, target, async, user, credential);
};

const fixture = {
  seeks: [] as number[], errors: [] as string[],
  setActive: (_active: boolean) => {},
};
Object.assign(window, { playerSeekFixture: fixture });
document.addEventListener("seeking", (e) => {
  if (e.target instanceof HTMLVideoElement) fixture.seeks.push(e.target.currentTime);
}, true);
window.addEventListener("error", (e) => fixture.errors.push(e.message));
api.boot = async () => ({ user: null, logged_in: false, base: "https://fixture.invalid", strict_security: true });
api.play = async () => ({ id: 991, ep_num: 1, title: "Seek fixture", duration: 90, video_url: "https://media.fixture.invalid/list.m3u8" });
api.video = async () => ({
  id: 991, title: "Seek fixture", description: "", cover: "", tags: [], score: 0,
  episode_count: 1, total_episodes: 1,
  episodes: [{ ep_num: 1, title: "one", duration: 90, status: 1 }],
  counts: { like: 0, collect: 0, comment: 0, hot: 0 },
  author: { id: 1, name: "Fixture" }, is_finished: true, is_original: 0,
});
function Fixture() {
  const [active, setActive] = useState(true);
  fixture.setActive = setActive;
  return <AppProvider>
    <div style={{ position: "relative", width: 900, height: 540 }}>
      <Feed videoIds={[991]} mode="home" active={active} bottomInset={0} />
    </div>
    <button onClick={() => setActive((v) => !v)}>切换播放页激活状态</button>
  </AppProvider>;
}
createRoot(document.querySelector("#root")!).render(<Fixture />);

// 自动检查真正的浏览器命中测试，而非仅匹配 CSS 字符串。
async function checkIdleSeekTarget() {
  const deadline = performance.now() + 20000;
  while (performance.now() < deadline) {
    const video = document.querySelector("video");
    const input = document.querySelector<HTMLInputElement>('input[aria-label="播放进度"]');
    if (video && input && video.currentTime > 0 && document.querySelector(".player-root.is-idle")) {
      const rect = input.getBoundingClientRect();
      if (document.elementFromPoint(rect.x + rect.width * .8, rect.y + rect.height / 2) !== input) {
        throw new Error("闲置进度条点击穿透到视频");
      }
      document.querySelector("#results")!.textContent = JSON.stringify({ passed: 1, failed: 0 });
      return;
    }
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  }
  throw new Error("等待播放或控制条隐藏超时");
}
void checkIdleSeekTarget().catch((error) => {
  fixture.errors.push(String(error));
  document.querySelector("#results")!.textContent = JSON.stringify({ passed: 0, failed: 1, error: String(error) });
});
