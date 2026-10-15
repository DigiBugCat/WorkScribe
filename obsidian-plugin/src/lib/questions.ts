import type { LiveAnswer } from './types';

export function askedOfYou(answer: LiveAnswer, name: string): boolean {
  if (answer.askedOfYou === true) return true;
  const names = name.split(',').map(n=>n.trim()).filter(Boolean);
  return names.some(n=>{
    const escaped=n.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
    // A vocative, not merely a mention ("What did Andrew decide?").
    return new RegExp(`^(?:hey\\s+)?${escaped}\\s*[,—:]|[,—:]\\s*${escaped}\\s*[?!,.]?$`,'i').test(answer.question.trim());
  });
}
export function rankQuestions(answers: LiveAnswer[], name: string): LiveAnswer[] {
  return [...answers].sort((a,b)=>Number(askedOfYou(b,name))-Number(askedOfYou(a,name)) || a.at-b.at);
}
