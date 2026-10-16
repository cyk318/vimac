import Foundation

/// 只读取当前文本控件或简单编辑块，正文最多32K且仅驻留内存。脚本不直接改正文。
enum BrowserEditingScript {
    static let source = #"""
    (()=>{
      const q=__REQUEST__, key=Symbol.for('com.cyk318.vimac.editSession');
      const fail=status=>JSON.stringify({status});
      if(!document.hasFocus())return fail('focus');
      // 只接受可无歧义映射为逻辑行的简单段落。换行是DOM块边界，不直接拼接textContent。
      function model(root) {
        if(root.querySelector('[contenteditable],img,svg,canvas,input,textarea,table,iframe,li,script,style,[hidden]'))throw Error('complex');
        const rows=[];let visited=0,total=0;
        function visit(element,depth) {
          if(++visited>4096 || depth>32 || rows.length>=512)throw Error('large_block');
          const isBlock=node=>node.nodeType===1 && (/^(DIV|P)$/.test(node.tagName) || node.classList.contains('ace-line'));
          const children=Array.from(element.childNodes);
          if(children.some(isBlock)) {
            for(const child of children) {
              if(isBlock(child))visit(child,depth+1);
              else if(child.nodeType!==8 && !(child.nodeType===3 && /^\s*$/.test(child.data)))throw Error('mixed_blocks');
            }
            return;
          }
          if(element.querySelector('div,p'))throw Error('complex');
          const breaks=element.querySelectorAll('br');
          if(breaks.length && (breaks.length!==1 || element.textContent!==''))throw Error('complex');
          const nodes=[],walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);
          let node,text='';
          while((node=walker.nextNode())) {
            if(++visited>4096 || total+text.length+node.length>32768)throw Error('large_block');
            nodes.push(node);text+=node.data;
          }
          const start=total;
          rows.push({element,nodes,text,start});total+=text.length+1;
          if(total>32769)throw Error('large_block');
        }
        visit(root,0);
        if(!rows.length)throw Error('complex');
        const text=rows.map(row=>row.text).join('\n');
        function at(offset) {
          for(const row of rows) {
            if(offset<row.start || offset>row.start+row.text.length)continue;
            let left=offset-row.start;
            for(const node of row.nodes) {if(left<=node.length)return [node,left];left-=node.length;}
            if(row.text.length===0)return [row.element,0];
          }
          throw Error('range');
        }
        function point(node,offset) {
          if(!node || !root.contains(node))return null;
          const probe=document.createRange();probe.setStart(node,offset);probe.collapse(true);
          for(const row of rows) {
            if(row.element.contains(node)) {
              const r=document.createRange();r.selectNodeContents(row.element);r.setEnd(node,offset);
              return row.start+r.toString().length;
            }
            const first=at(row.start),boundary=document.createRange();boundary.setStart(first[0],first[1]);boundary.collapse(true);
            if(probe.compareBoundaryPoints(Range.START_TO_START,boundary)<=0)return row.start;
          }
          return text.length;
        }
        return {text,at,point,identity:rows.map(row=>row.element)};
      }
      let p=document[key];
      if(q.action==='begin') {
        let e=document.activeElement, control=e && /^(INPUT|TEXTAREA)$/.test(e.tagName),lineEditing=true;
        if(control) {
          if(e.disabled || e.readOnly || (e.tagName==='INPUT' && !['text','search','url','tel'].includes(e.type)))return fail('unsupported');
          if(e.selectionStart===null)return fail('unsupported');
        } else {
          const s=getSelection();
          if(!s || !s.anchorNode || !s.isCollapsed)return fail('selection');
          let node=s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement;
          e=node.closest('[contenteditable="true"]');
          if(!e || !node.isContentEditable || !e.isContentEditable)return fail('unsupported');
          try { model(e); }
          catch(error) {
            // 整个编辑根含复杂对象时只保留当前简单块能力，不伪造跨块换行。
            const line=node.closest('.ace-line');
            if(!line || !e.contains(line))return fail(error.message);
            const parent=line.parentElement;
            let region=null;
            if(parent && parent!==e && e.contains(parent)) {
              try {if(model(parent).identity.length>1)region=parent;}catch(_){}
            }
            e=region || line;lineEditing=!!region;
            try {model(e);}catch(error){return fail(error.message);}
          }
        }
        p={element:e,control,lineEditing,token:q.token,settled:true};
        document[key]=p;
      }
      if(!p || p.token!==q.token || !p.element.isConnected)return fail('stale');
      const e=p.element;
      if(p.control ? document.activeElement!==e || e.readOnly || e.disabled : !e.isContentEditable)return fail('focus');
      if(p.control && e.tagName==='INPUT' && !['text','search','url','tel'].includes(e.type))return fail('unsupported');
      let layout;
      if(!p.control)try {layout=model(e);}catch(error){return fail(error.message);}
      function text(){return p.control?e.value:layout.text;}
      function selection() {
        if(p.control) return e.selectionDirection==='backward'
          ? [e.selectionEnd,e.selectionStart]:[e.selectionStart,e.selectionEnd];
        const s=getSelection();return [layout.point(s.anchorNode,s.anchorOffset),layout.point(s.focusNode,s.focusOffset)];
      }
      let value=text(), pair=selection();
      if(value.length>32768 || pair.some(x=>x===null))return fail('unsupported');
      if(q.action==='select') {
        if(value!==q.expected || pair[0]!==q.beforeAnchor || pair[1]!==q.beforeFocus)return fail('stale');
        const boundaries=new Set(Array.from(new Intl.Segmenter('en',{granularity:'grapheme'}).segment(value),p=>p.index).concat(value.length));
        if(!boundaries.has(q.anchor) || !boundaries.has(q.focus))return fail('range');
        if(p.control)e.setSelectionRange(Math.min(q.anchor,q.focus),Math.max(q.anchor,q.focus),q.anchor>q.focus?'backward':'forward');
        else {const a=layout.at(q.anchor),f=layout.at(q.focus);getSelection().setBaseAndExtent(a[0],a[1],f[0],f[1]);}
        pair=selection();
        if(pair[0]!==q.anchor || pair[1]!==q.focus)return fail('unconfirmed');
        p.settled=false;p.expected=value;p.anchor=q.anchor;p.focus=q.focus;
        p.identity=layout?.identity;
        requestAnimationFrame(()=>{p.settled=true;});
      }
      if(q.action==='confirm') {
        if(!p.settled)return fail('pending');
        if(!p.control && (!p.identity || p.identity.length!==layout.identity.length || p.identity.some((node,i)=>node!==layout.identity[i])))return fail('stale');
        if(value!==p.expected || pair[0]!==p.anchor || pair[1]!==p.focus)return fail('stale');
      }
      return JSON.stringify({status:'ok',text:value,anchor:pair[0],focus:pair[1],
        control:p.control,multiline:p.control && e.tagName==='TEXTAREA',block:!p.control,lineEditing:p.lineEditing});
    })()
    """#
}
