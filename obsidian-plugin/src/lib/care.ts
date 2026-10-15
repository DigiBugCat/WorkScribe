/** Pure timing and word-diff rules shared by editor and tests. */
export function fadeCountdown(purgeAt: string, now = Date.now()): string {
  const left = Math.max(0, Date.parse(purgeAt) - now);
  if (!Number.isFinite(left)) return 'Transcript fade time unavailable';
  if (!left) return 'Transcript fading';
  return `Transcript fades in ${left >= 3600000 ? Math.floor(left / 3600000) + ' h' : Math.max(1, Math.floor(left / 60000)) + ' min'}`;
}
export interface WordChange { text: string; kind: 'same' | 'added' | 'removed' }
export function wordDiff(before: string, after: string): WordChange[] {
  const a = before.match(/[\p{L}\p{N}][\p{L}\p{N}’'.-]*[\p{L}\p{N}]|[\p{L}\p{N}]|[^\s\p{L}\p{N}]+|\s+/gu) ?? [], b = after.match(/[\p{L}\p{N}][\p{L}\p{N}’'.-]*[\p{L}\p{N}]|[\p{L}\p{N}]|[^\s\p{L}\p{N}]+|\s+/gu) ?? [];
  // Bound memory for pathological model output.
  if (a.length * b.length > 250000) return [{text: after, kind: 'added'}];
  const dp = Array.from({length:a.length+1}, () => new Uint16Array(b.length+1));
  for(let i=a.length-1;i>=0;i--) for(let j=b.length-1;j>=0;j--)
    dp[i][j] = a[i] === b[j] ? dp[i+1][j+1]+1 : Math.max(dp[i+1][j], dp[i][j+1]);
  let i=0,j=0; const out: WordChange[]=[];
  while(i<a.length || j<b.length) {
    if(i<a.length && j<b.length && a[i]===b[j]) {out.push({text:b[j++],kind:'same'});i++;}
    else if(j<b.length && (i===a.length || dp[i][j+1]>=dp[i+1][j])) out.push({text:b[j++],kind:'added'});
    else out.push({text:a[i++],kind:'removed'});
  }
  return out;
}
export function continuation(text: string, block: string, owned=false): string {
  const indent = ' '.repeat(block.match(/^(\s*(?:[-+*]|[0-9]+[.)])\s+)/)?.[0].length ?? 0);
  const escape = (s:string) => s.replace(/([\\*_])/g,'\\$1');
  return text.split('\n').map(line => indent + (owned ? line : '*' + escape(line) + '*')).join('\n');
}
