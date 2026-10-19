import type { EngineStatus } from '../../lib/types';
export function surfaceStatus(status:EngineStatus,recording:boolean):string {
  return [recording?'Recording':undefined,status.model==='ready'?'Model ready':status.model==='loading'?'Model loading':'Model missing',status.paused?'Paused · '+status.paused:undefined].filter(Boolean).join(' · ');
}
