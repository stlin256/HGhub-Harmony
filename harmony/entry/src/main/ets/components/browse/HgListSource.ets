/**
 * LazyForEach 通用数据源：reset / append / update，供瀑布流、网格与横向列表复用。
 * 只做增量通知，避免整表重建导致滚动位置跳动。
 */
export class HgListSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  resetAll(items: T[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  append(items: T[]): void {
    const start = this.items.length;
    for (let i = 0; i < items.length; i++) {
      this.items.push(items[i]);
    }
    for (let i = start; i < this.items.length; i++) {
      for (let j = 0; j < this.listeners.length; j++) {
        this.listeners[j].onDataAdd(i);
      }
    }
  }

  clear(): void {
    this.items = [];
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 当前快照（用于把排序后的数组写回数据源）。 */
  snapshot(): T[] {
    return this.items.slice(0);
  }
}
