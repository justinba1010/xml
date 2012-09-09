(*
 * (c) 2004-2012 Anastasia Gornostaeva
 *)

type element =
  | Xmlelement of (string * (string * string) list * element list)
  | Xmlcdata of string

exception NonXmlelement
exception Expected of string

let decode = Xml_decode.decode
let encode = Xml_encode.encode

let rec attrs_to_string attrs =
  let attr_to_string attr =
    match attr with
      | (name, value) -> 
	        Printf.sprintf " %s='%s'" name (encode value)
  in List.fold_left (^) "" (List.map attr_to_string attrs)
       
let rec element_to_string el =
  match el with
    | Xmlelement (name, attrs, els) ->
        if List.length els > 0 then
          (Printf.sprintf "<%s" name) ^ (attrs_to_string attrs) ^ ">" ^
            (List.fold_left (^) "" (List.map element_to_string els)) ^
            (Printf.sprintf "</%s>" name)
        else
          (Printf.sprintf "<%s" name) ^ (attrs_to_string attrs) ^ "/>"
    | Xmlcdata chunk -> encode chunk
        
let rec get_tag (el:element) (path:string list) =
  match el with
    | Xmlelement (_,_, els) ->
        if path = [] then el
        else
          let name = List.hd path in
          let ctag = List.find
            (function
               | Xmlelement (name1, _,_) ->
                   name = name1
               | Xmlcdata _ ->
			             false
            ) els in
            get_tag ctag (List.tl path)
    | Xmlcdata _ -> raise NonXmlelement
        
let get_tag_full_path el path =
  match el with
    | Xmlelement (tag, _,_) ->
        if tag = List.hd path then get_tag el (List.tl path)
        else raise Not_found
    | Xmlcdata _cdata -> 
	      raise NonXmlelement
          
let get_subel ?(path=[]) el =
  match get_tag el path with
    | Xmlelement (_, _, els) ->
	      List.find (function
			               | Xmlelement (_, _, _) -> true
			               | Xmlcdata _ -> false
		              ) els
    | Xmlcdata _ -> raise NonXmlelement
        
let get_subels ?(path=[]) ?(tag="") el =
  match get_tag el path with
    | Xmlelement (_, _, els) ->
        if tag = "" then els
	      else if els = [] then []
	      else
          List.find_all (function x ->
                           match x with
                             | Xmlelement (tag1, _,_) -> tag1 = tag
                             | Xmlcdata _ -> false
                        ) els
    | Xmlcdata _ -> 
	      raise NonXmlelement
          
let get_attr_s el ?(path=[]) (attrname:string) =
  match get_tag el path with
    | Xmlelement (_, attrs, _) ->
        List.assoc attrname attrs
    | Xmlcdata _ -> raise NonXmlelement
        
let filter_attrs attrs =
  let checker (_k,v) = if v = "" then false else true in
    List.filter checker attrs
      
let rec collect_cdata els acc =
  match els with
    | [] -> String.concat "" (List.rev acc)
    | (Xmlcdata cdata) :: l -> collect_cdata l (cdata :: acc)
    | Xmlelement _ :: l -> collect_cdata l acc
        
let get_cdata ?(path=[]) el =
  match get_tag el path with
    | Xmlelement (_, _, els) -> collect_cdata els []
    | Xmlcdata _ -> raise NonXmlelement
        
let make_element name attrs els =
  Xmlelement (name, attrs, els)
    
let make_simple_cdata name cdata =
  Xmlelement (name, [], [Xmlcdata cdata])
    
let safe_get_attr_s xml ?(path=[]) attrname =
  try get_attr_s xml ~path attrname with _ -> ""
    
let match_tag tag element =
  let b = 
    match element with
      | Xmlelement (tag1, _, _) -> tag1 = tag
      | Xmlcdata _ -> false
  in
    if not b then
	    raise (Expected tag)
          
let exists_element tag els =
  List.exists (function
		             | Xmlelement (tag1, _, _) -> tag1 = tag
		             | Xmlcdata _ -> false
	            ) els
    
    
let find_subtag (subels:element list) (tag:string) =
  List.find (function
               | Xmlelement (tag1, _, _) -> tag1=tag
               | Xmlcdata _ -> false
            ) subels
    
let get_tagname el =
  match el with
    | Xmlelement (name, _, _) -> name
    | Xmlcdata _ -> raise NonXmlelement
        
let match_xml el tag (attrs:(string * string) list) =
  match el with
    | Xmlelement (name, _, _) ->
        if name = tag then
	        (try
             List.iter (fun (a, v) ->
			                    if get_attr_s el a <> v then 
				                    raise Not_found) attrs;
             true
           with _ -> false)
        else
          false
    | Xmlcdata _ -> false
        
let mem_xml xml path tag attrs =
  if get_tagname xml <> List.hd path then false
  else
    try
	    let els = get_subels xml ~path:(List.tl path) ~tag in
	      List.exists (fun el ->
			                 try
			                   List.iter (fun (a, v) -> 
					                            if get_attr_s el a <> v 
					                            then raise Not_found) attrs;
			                   true
			                 with _ -> false
			              ) els
    with _ -> false
      
let get_by_xmlns xml ?path ?tag xmlns =
  let els = get_subels xml ?path ?tag in
    List.find (fun x ->
		             if safe_get_attr_s x "xmlns" = xmlns then true
		             else false) els
      
module XmlParser = Xmllexer.M
module XStanza = Xmllexer.XmlStanza
open XStanza

let parse_document strm =
  let next_token = XmlParser.make_lexer strm in
  let stack = Stack.create () in
  let add_element el =
    let (qname, attrs, subels) = Stack.pop stack in
      Stack.push (qname, attrs, (el :: subels)) stack
  in
  let rec loop () =
    match next_token () with
      | Some t -> (
        match t with
          | StartTag (name, attrs, selfclosing) ->
            let el = (name, attrs, []) in
              if selfclosing then (
                if Stack.is_empty stack then (
                  Stack.push el stack;
                  loop ();
                ) else (
                  add_element (Xmlelement el);
                  loop ()
                )
              ) else (
                Stack.push el stack;
                loop ();
                loop ()
              )
          | EndTag _name ->
            if Stack.length stack > 1 then 
              add_element (Xmlelement (Stack.pop stack))
            else
              ()
          | Text text ->
            add_element (Xmlcdata text);
            loop ()
          | Doctype _              
          | PI _ ->
            loop ()
      )
      | None -> ()
  in
    try
      loop ();
      let el = Stack.pop stack in
        Xmlelement el
    with XmlParser.Located_exn ((line, col), exn) ->
      match exn with
        | XmlParser.Error msg ->
          Printf.eprintf "%d:%d %s\n" line col msg;
          Pervasives.exit 127
        | XmlParser.Error_ExpectedChar chs ->
          Printf.eprintf "%d:%d Expected '%s'\n" line col
            (String.make 1 (List.hd chs));
          Pervasives.exit 127          
        | XmlParser.Error_CharToken u ->
          let chs = XmlParser.S.encode_unicode u in
          let str = String.create (List.length chs) in
          let rec iteri i = function
            | [] -> ()
            | x :: xs -> str.[i] <- x; iteri (succ i) xs
          in
            iteri 0 chs;
            Printf.eprintf "%d:%d Unexpected character token %S\n" line col str;
            Pervasives.exit 127
        | exn ->
          Printf.eprintf "%d:%d %s\n" line col (Printexc.to_string exn);
          Pervasives.exit 127

