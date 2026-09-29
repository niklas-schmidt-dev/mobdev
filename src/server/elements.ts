import { XMLParser } from 'fast-xml-parser';
import type { UIElement } from '../shared/schema';
import { AppError } from './errors';

export function parseElements(xml: string): UIElement[] {
  const parsed: unknown = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '', parseAttributeValue: false, processEntities: false }).parse(xml);
  const result: UIElement[] = [];
  function visit(value: unknown, tag = '') {
    if (Array.isArray(value)) { value.forEach(item => visit(item, tag)); return; }
    if (!value || typeof value !== 'object') return;
    const node = value as Record<string, unknown>;
    const string = (key: string) => typeof node[key] === 'string' ? String(node[key]) : '';
    if (node.bounds || node.x !== undefined) {
      const match = string('bounds').match(/^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$/);
      const x = match ? Number(match[1]) : Number(node.x ?? 0);
      const y = match ? Number(match[2]) : Number(node.y ?? 0);
      const width = match ? Number(match[3]) - x : Number(node.width ?? 0);
      const height = match ? Number(match[4]) - y : Number(node.height ?? 0);
      if (width > 0 && height > 0 && string('visible') !== 'false' && string('displayed') !== 'false') result.push({
        id: string('resource-id') || string('name') || `element-${result.length}`,
        text: string('text') || string('value'), label: string('content-desc') || string('label') || string('name'),
        type: string('class') || string('type') || tag, bounds: { x, y, width, height }, enabled: string('enabled') !== 'false',
      });
    }
    for (const [key, item] of Object.entries(node)) if (typeof item === 'object') visit(item, key);
  }
  visit(parsed);
  return result;
}
export function findElement(elements: UIElement[], target: string, requireEnabled = false): UIElement {
  const normalized = target.toLocaleLowerCase();
  const eligible = requireEnabled ? elements.filter(e => e.enabled) : elements;
  const exact = eligible.filter(e => [e.id, e.text, e.label].some(value => value.toLocaleLowerCase() === normalized));
  const candidates = exact.length ? exact : eligible.filter(e => [e.text, e.label].some(value => value.toLocaleLowerCase().includes(normalized)));
  if (!candidates.length) throw new AppError(`Element not found: ${target}`, 404);
  // A label and its containing button often share the same text; choose the smallest hit target only if nested.
  const unique = candidates.filter((e, i) => candidates.findIndex(other => JSON.stringify(other.bounds) === JSON.stringify(e.bounds)) === i);
  if (unique.length > 1) {
    const sorted = unique.toSorted((a,b) => a.bounds.width * a.bounds.height - b.bounds.width * b.bounds.height);
    const smallest = sorted[0]!;
    if (sorted.every(e => smallest.bounds.x >= e.bounds.x && smallest.bounds.y >= e.bounds.y && smallest.bounds.x + smallest.bounds.width <= e.bounds.x + e.bounds.width && smallest.bounds.y + smallest.bounds.height <= e.bounds.y + e.bounds.height)) return smallest;
    throw new AppError(`Ambiguous element: ${target} (${unique.length} matches). Use an exact resource ID or coordinates.`, 409);
  }
  return unique[0]!;
}
