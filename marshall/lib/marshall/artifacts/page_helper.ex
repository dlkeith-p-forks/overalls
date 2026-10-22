defmodule Marshall.Artifacts.PageHelper do
  @moduledoc """
  The inline helper prepended to served pages: `window.marshallStorage` turns
  page storage into promises over the parent postMessage bridge.
  """

  @script """
  <script>(()=>{let n=0;const p=new Map();addEventListener("message",e=>{const d=e.data;if(e.source!==parent||!d||d.type!=="marshall-artifact-storage-result"||!p.has(d.id))return;const[r,j]=p.get(d.id);p.delete(d.id);d.ok?r(d.op==="list"?d.keys:d.value??null):j(new Error(d.error||"storage_unavailable"))});const c=(op,namespace,extra)=>new Promise((r,j)=>{const id=++n;p.set(id,[r,j]);parent.postMessage({type:"marshall-artifact-storage",id,op,namespace,...extra},"*")});const s=ns=>({get:k=>c("get",ns,{key:k}),set:(k,v)=>c("set",ns,{key:k,value:String(v)}),delete:k=>c("delete",ns,{key:k}),list:x=>c("list",ns,x===undefined?{}:{prefix:x})});window.marshallStorage={personal:s("personal"),shared:s("shared")}})();</script>
  """

  @spec script() :: String.t()
  def script, do: @script

  @doc "Inserts the helper after a leading doctype (keeping standards mode), else prepends it."
  @spec inject(binary()) :: binary()
  def inject(page) when is_binary(page) do
    case Regex.run(~r/\A\s*<!doctype[^>]*>/i, page) do
      [doctype] ->
        doctype <>
          @script <> binary_part(page, byte_size(doctype), byte_size(page) - byte_size(doctype))

      nil ->
        @script <> page
    end
  end
end
