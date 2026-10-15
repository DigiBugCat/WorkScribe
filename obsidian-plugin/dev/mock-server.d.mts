export interface MockServer {
  port: number;
  token: string;
  discoveryPath: string | null;
  startRecording(title?: string): void;
  stopRecording(): void;
  close(): Promise<void>;
}
export function startMockServer(opts?: {
  port?: number;
  token?: string;
  discovery?: string | false;
  vault?: string;
  speed?: number;
  live?: boolean;
  quiet?: boolean;
}): Promise<MockServer>;
