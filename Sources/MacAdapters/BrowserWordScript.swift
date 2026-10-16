import Foundation

enum BrowserWordScript {
    /// 与 TextBuffer 的词分组保持一致；只借助 Intl.Segmenter 切字素，不采用浏览器的词典分词。
    static let algorithm = #"""
    function wordDestination(text, offset, command) {
      if (!['wordForward','wordBackward','wordEnd'].includes(command)) throw Error('command');
      if (text.length > 32768 || !Number.isInteger(offset)) throw Error('range');
      const parts=Array.from(new Intl.Segmenter('en',{granularity:'grapheme'}).segment(text));
      const chars=parts.map(p=>p.segment), offsets=parts.map(p=>p.index).concat(text.length);
      let cursor=offsets.indexOf(offset);
      if (cursor<0) throw Error('boundary');
      if (command!=='wordBackward' && offset===text.length) return offset;
      const kind=i=>i>=chars.length?0:/^\p{White_Space}+$/u.test(chars[i])?0:
        (/\p{L}|\p{N}/u.test(chars[i]) || chars[i]==='_')?1:2;
      if (command==='wordForward') {
        const k=kind(cursor);while(cursor<chars.length && kind(cursor)===k)cursor++;
        while(cursor<chars.length && kind(cursor)===0)cursor++;
      } else if (command==='wordBackward') {
        cursor=Math.max(0,cursor-1);while(cursor>0 && kind(cursor)===0)cursor--;
        const k=kind(cursor);while(cursor>0 && kind(cursor-1)===k)cursor--;
      } else {
        cursor=Math.min(chars.length,cursor+1);while(cursor<chars.length && kind(cursor)===0)cursor++;
        const k=kind(cursor);while(cursor+1<chars.length && kind(cursor+1)===k)cursor++;
      }
      const newline=i=>i>=0 && i<chars.length && /^(\r\n|[\n\r\v\f\u0085\u2028\u2029])$/u.test(chars[i]);
      let start=cursor;while(start>0 && !newline(start-1))start--;
      if ((cursor===chars.length || newline(cursor)) && cursor>start)cursor--;
      return offsets[cursor];
    }
    """#

    static let source = "(() => {\n" + algorithm + #"""
      const req=JSON.parse('__REQUEST__');
      const reply=(status, fields={})=>JSON.stringify({status,...fields});
      const key=Symbol.for('com.cyk318.vimac.pendingWord');
      const s=getSelection();
      function position(e) {
        if (!s || !s.isCollapsed || !s.anchorNode || !e.contains(s.anchorNode)) return null;
        const r=document.createRange();r.selectNodeContents(e);r.setEnd(s.anchorNode,s.anchorOffset);
        return r.toString().length;
      }
      if (req.action==='confirm') {
        const p=document[key];
        if (!p || p.token!==req.token || !document.hasFocus()) return reply('stale');
        if (!p.settled) return reply('pending');
        delete document[key];
        return reply(p.element.isConnected && p.element.textContent===p.text && position(p.element)===p.offset
          ? 'ok' : 'rejected', {actual:position(p.element)});
      }
      if (req.action!=='move' || !document.hasFocus() || !s || !s.isCollapsed || !s.anchorNode) return reply('no_caret');
      let e=s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement;
      while(e && e.getAttribute('contenteditable')!=='true') {
        if(e.getAttribute('contenteditable')==='false')return reply('readonly');
        e=e.parentElement;
      }
      if(!e || !e.isContentEditable)return reply('unsupported_editor');
      const paragraph=(s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement).closest('.ace-line');
      if(paragraph && e.contains(paragraph))e=paragraph;
      if(e.querySelector('[contenteditable],br,img,svg,canvas,input,textarea,table,iframe,div,p,li'))return reply('complex_block');
      const text=e.textContent,before=position(e);
      if(text.length>32768)return reply('large_block');
      let requested;
      try { requested=wordDestination(text,before,req.command); } catch (_) { return reply('unsupported_boundary'); }
      const fields={before,requested,block_length:text.length};
      if(requested===before)return reply('unchanged',fields);
      // 读取、计算、设置处于同一个浏览器任务，中间不会夹入异步DOM更新或切换标签。
      const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);
      let left=requested,node;
      while((node=walker.nextNode())) {
        if(left<=node.data.length) {
          s.setBaseAndExtent(node,left,node,left);
          if(position(e)!==requested)return reply('unconfirmed',fields);
          const p={token:req.token,element:e,text,offset:requested,settled:false};
          document[key]=p;
          // 等一帧让selectionchange进入宿主处理；由独立请求确认，不以同步结果假装通过。
          requestAnimationFrame(()=>{p.settled=true;});
          setTimeout(()=>{if(document[key]===p)delete document[key];},2000);
          return reply('moved',fields);
        }
        left-=node.data.length;
      }
      return reply('unconfirmed',fields);
    })()
    """#
}
