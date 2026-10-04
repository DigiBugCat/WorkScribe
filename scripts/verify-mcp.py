"""Run with: uv run --with mcp python scripts/verify-mcp.py"""
import asyncio
import json
import os
from pathlib import Path
import tempfile
import uuid

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

async def main():
    executable = Path(os.environ.get('WORKSCRIBE_EXECUTABLE', str(Path(__file__).resolve().parent.parent / 'dist/WorkScribe.app/Contents/MacOS/WorkScribe')))
    with tempfile.TemporaryDirectory(prefix='workscribe-mcp-test-') as folder:
        mid, sid = str(uuid.uuid4()), str(uuid.uuid4())
        target = Path(folder) / mid
        target.mkdir()
        fixture = {'id': mid, 'title': 'Synthetic MCP check', 'startedAt': '2026-10-03T16:00:00Z',
                   'status': 'recording', 'partials': {'microphone': 'draft text'},
                   'segments': [{'id': sid, 'source': 'microphone', 'speaker': 'microphone:speaker-1',
                                 'start': 2.0, 'end': 3.0, 'text': 'Release on Friday.'}]}
        (target / 'transcript.json').write_text(json.dumps(fixture))
        params = StdioServerParameters(command=str(executable), args=['--mcp'], env={**os.environ, 'WORKSCRIBE_DATA_DIR': folder})
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                tools = await session.list_tools()
                assert len(tools.tools) == 4
                async def call(name, arguments=None):
                    result = await session.call_tool(name, arguments or {})
                    assert not result.is_error, result
                    return json.loads(result.content[0].text)
                assert (await call('list_meetings'))['meetings'][0]['meeting_id'] == mid
                assert (await call('get_live_transcript'))['active']
                assert (await call('get_transcript', {'meeting_id': mid}))['segments'][0]['segment_id'] == sid
                assert (await call('search_transcripts', {'query': 'FRIDAY'}))['hits'][0]['segment_id'] == sid
                assert not (await call('search_transcripts', {'query': 'draft'}))['hits']
                bad = await session.call_tool('get_transcript', {'meeting_id': '../outside'})
                assert bad.is_error
                fixture['status'] = 'complete'
                (target / 'transcript.json').write_text(json.dumps(fixture))
                assert not (await call('get_live_transcript'))['active']
    print('PASS: official MCP client initialized, discovered four tools, read live updates, searched citations, rejected path traversal.')

asyncio.run(main())
