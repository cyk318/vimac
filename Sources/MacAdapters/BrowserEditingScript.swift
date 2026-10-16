import Foundation

/// 只读取当前文本控件或简单编辑块，正文最多32K且仅驻留内存。脚本不直接改正文。
enum BrowserEditingScript {
    static let source = #"""
    (()=>{
      const q=__REQUEST__, key=Symbol.for('com.cyk318.vimac.editSession');
      const fail=status=>JSON.stringify({status});
      if(!document.hasFocus())return fail('focus');
      let p=document[key];
      if(q.action==='begin') {
        let e=document.activeElement, control=e && /^(INPUT|TEXTAREA)$/.test(e.tagName);
        if(control) {
          if(e.disabled || e.readOnly || (e.tagName==='INPUT' && !['text','search','url','tel'].includes(e.type)))return fail('unsupported');
          if(e.selectionStart===null)return fail('unsupported');
        } else {
          const s=getSelection();
          if(!s || !s.anchorNode || !s.isCollapsed)return fail('selection');
          let node=s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement;
          e=node.closest('[contenteditable="true"]');
          if(!e || !node.isContentEditable || !e.isContentEditable)return fail('unsupported');
          const line=node.closest('.ace-line');
          if(line && e.contains(line))e=line;
          if(e.querySelector('[contenteditable],br,img,svg,canvas,input,textarea,table,iframe,div,p,li'))return fail('complex');
        }
        p={element:e,control,token:q.token,settled:true};
        document[key]=p;
      }
      if(!p || p.token!==q.token || !p.element.isConnected)return fail('stale');
      const e=p.element;
      if(p.control ? document.activeElement!==e || e.readOnly || e.disabled : !e.isContentEditable)return fail('focus');
      if(p.control && e.tagName==='INPUT' && !['text','search','url','tel'].includes(e.type))return fail('unsupported');
      if(!p.control && e.querySelector('[contenteditable],br,img,svg,canvas,input,textarea,table,iframe,div,p,li'))return fail('complex');
      function text(){return p.control?e.value:e.textContent;}
      function point(node,offset) {
        if(!node || !e.contains(node))return null;
        const r=document.createRange();r.selectNodeContents(e);r.setEnd(node,offset);return r.toString().length;
      }
      function selection() {
        if(p.control) return e.selectionDirection==='backward'
          ? [e.selectionEnd,e.selectionStart]:[e.selectionStart,e.selectionEnd];
        const s=getSelection();return [point(s.anchorNode,s.anchorOffset),point(s.focusNode,s.focusOffset)];
      }
      function at(offset) {
        if(!e.firstChild && offset===0)return [e,0];
        const walker=document.createTreeWalker(e,NodeFilter.SHOW_TEXT);
        let node,left=offset;
        while((node=walker.nextNode())) {if(left<=node.length)return [node,left];left-=node.length;}
        throw Error('range');
      }
      let value=text(), pair=selection();
      if(value.length>32768 || pair.some(x=>x===null))return fail('unsupported');
      if(q.action==='select') {
        if(value!==q.expected || pair[0]!==q.beforeAnchor || pair[1]!==q.beforeFocus)return fail('stale');
        const boundaries=new Set(Array.from(new Intl.Segmenter('en',{granularity:'grapheme'}).segment(value),p=>p.index).concat(value.length));
        if(!boundaries.has(q.anchor) || !boundaries.has(q.focus))return fail('range');
        if(p.control)e.setSelectionRange(Math.min(q.anchor,q.focus),Math.max(q.anchor,q.focus),q.anchor>q.focus?'backward':'forward');
        else {const a=at(q.anchor),f=at(q.focus);getSelection().setBaseAndExtent(a[0],a[1],f[0],f[1]);}
        pair=selection();
        if(pair[0]!==q.anchor || pair[1]!==q.focus)return fail('unconfirmed');
        p.settled=false;p.expected=value;p.anchor=q.anchor;p.focus=q.focus;
        requestAnimationFrame(()=>{p.settled=true;});
      }
      if(q.action==='confirm') {
        if(!p.settled)return fail('pending');
        if(value!==p.expected || pair[0]!==p.anchor || pair[1]!==p.focus)return fail('stale');
      }
      return JSON.stringify({status:'ok',text:value,anchor:pair[0],focus:pair[1],
        control:p.control,multiline:p.control && e.tagName==='TEXTAREA',block:!p.control});
    })()
    """#
}
