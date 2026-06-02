/* eslint-disable no-console,@typescript-eslint/no-explicit-any */

import { NextResponse } from "next/server";

import { getConfig } from "@/lib/config";

export const runtime = 'nodejs';

export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const url = searchParams.get('url');
  const source = searchParams.get('moontv-source');
  if (!url) {
    return NextResponse.json({ error: 'Missing url' }, { status: 400 });
  }

  const config = await getConfig();
  const liveSource = config.LiveConfig?.find((s: any) => s.key === source);
  if (!liveSource) {
    return NextResponse.json({ error: 'Source not found' }, { status: 404 });
  }
  const ua = liveSource.ua || 'AptvPlayer/1.4.10';

  let response: Response | null = null;
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;

  // 统一释放 reader，避免直播切台或请求中断后仍占用上游流资源。
  const releaseReader = () => {
    if (!reader) return;
    try {
      reader.releaseLock();
    } catch (e) {
      // Reader may already be released after cancel/error.
    }
    reader = null;
  };

  try {
    const decodedUrl = decodeURIComponent(url);
    response = await fetch(decodedUrl, {
      signal: request.signal,
      headers: {
        'User-Agent': ua,
      },
    });
    if (!response.ok) {
      return NextResponse.json({ error: 'Failed to fetch segment' }, { status: 500 });
    }

    const headers = new Headers();
    headers.set('Content-Type', 'video/mp2t');
    headers.set('Access-Control-Allow-Origin', '*');
    headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    headers.set('Access-Control-Allow-Headers', 'Content-Type, Range, Origin, Accept');
    headers.set('Accept-Ranges', 'bytes');
    headers.set('Access-Control-Expose-Headers', 'Content-Length, Content-Range');

    // 客户端取消播放时停止 pump，避免继续读取已无消费者的直播分片。
    let cancelled = false;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        if (!response?.body) {
          controller.close();
          return;
        }

        reader = response.body.getReader();

        const pump = (): void => {
          if (cancelled || !reader) return;

          reader.read().then(({ done, value }) => {
            if (cancelled || !reader) return;

            if (done) {
              controller.close();
              releaseReader();
              return;
            }

            controller.enqueue(value);
            pump();
          }).catch((error) => {
            if (!cancelled) {
              controller.error(error);
            }
            releaseReader();
          });
        };

        pump();
      },
      async cancel() {
        cancelled = true;

        if (reader) {
          try {
            await reader.cancel();
          } catch (e) {
            // Ignore cancellation errors.
          }
          releaseReader();
        }

        if (response?.body) {
          try {
            await response.body.cancel();
          } catch (e) {
            // Ignore cancellation errors.
          }
        }
      }
    });

    return new Response(stream, { headers });
  } catch (error) {
    releaseReader();

    if (response?.body) {
      try {
        await response.body.cancel();
      } catch (e) {
        // Ignore cancellation errors.
      }
    }

    return NextResponse.json({ error: 'Failed to fetch segment' }, { status: 500 });
  }
}
