(*
 * (c) 2007 Anastasia Gornostaeva <ermine@ermine.pp.ru>
 *)

open Fstream
open Encoding

exception LexerError of string
exception UnknownEntity of string

type production =
   | StartElement of string * (string * string) list
   | EndElement of string
   | Pi of string * string
   | Comment of string
   | Whitespace of string
   | Cdata of string
   | Text of string
   | Doctype of string * Xml.external_id option * string

type parser_t = {
   mutable encoding : string;
   mutable standalone : bool;
   base_uri : string;

   mutable fparser : parser_t -> char Stream.t -> unit;
   mutable fencoder : int -> (int, char list) Fstream.t;
   process_entity : string -> int;
}
and lstream = | Lexer of (parser_t -> int -> lstream) 
	      | Switch of 
		   (char -> (char, int) Fstream.t) * (parser_t -> int -> lstream)
	      | EndLexer

let accept_if str f =
   let len = String.length str in
   let rec aux_accept i state ch =
      if i < len then
	 if ch = Uchar.of_char str.[i] then
	    Lexer (aux_accept (i+1))
	 else 
	    raise (LexerError (Printf.sprintf "expected %S" str))
      else
	 f state ch
   in
      Lexer (aux_accept 0)

let rec skip_blank f state ucs4 =
   if Xmlchar.is_blank ucs4 then
      Lexer (skip_blank f)
   else
      f state ucs4

let after_blank nextf state ucs4 =
   if Xmlchar.is_blank ucs4 then
      Lexer (skip_blank nextf)
   else
      raise (LexerError "expected space")

let fencoder state buf ucs4 =
   match state.fencoder ucs4 with
      | F f -> state.fencoder <- f
      | R (r, f) ->
	   List.iter (fun c -> Buffer.add_char buf c) r;
	   state.fencoder <- f

(*
let parse_ncname nextf state ucs4 =
   let buf = Buffer.create 30 in
   let rec get_name state ucs4 =
      if Xmlchar.is_ncnamechar ucs4 then (
         fencoder state buf ucs4;
         Lexer get_name
      ) else (
         let name = Buffer.contents buf in
            Buffer.clear buf;
            nextf name state ucs4
      )
   in
      if Xmlchar.is_first_ncnamechar ucs4 then (
	 fencoder state buf ucs4;
	 Lexer get_name
      )
      else
	 raise (LexerError "invalid name")

let parse_qname nextf state ucs4 =
   parse_ncname (fun ncname1 state ucs4 ->
		    if ucs4 = Uchar.u_colon then
		       parse_ncname (fun ncname2 state ucs4 ->
					nextf (ncname1, ncname2) state ucs4)
			  state ucs4
		    else
		       nextf ("", ncname1) state ucs4
		) state ucs4
*)

let parse_name nextf state ucs4 =
   let buf = Buffer.create 30 in
   let rec get_name state ucs4 =
      if Xmlchar.is_namechar ucs4 then (
         fencoder state buf ucs4;
         Lexer get_name
      ) else (
         let name = Buffer.contents buf in
            Buffer.clear buf;
            nextf name state ucs4
      )
   in
      if Xmlchar.is_first_namechar ucs4 then (
	 fencoder state buf ucs4;
	 Lexer get_name
      )
      else
	 raise (LexerError "invalid name")
      
let parse_decimal_charref nextf state ucs4 =
   let rec get_decimal acc state ucs4 =
      if ucs4 >= Uchar.of_char '0' && ucs4 <= Uchar.of_char '9' then
	 Lexer (get_decimal (acc * 10 + (ucs4 - Uchar.of_char '0')))
      else if ucs4 = Uchar.u_semicolon then
	 nextf acc
      else
	 raise (LexerError "malformed character reference")
   in
      get_decimal 0 state ucs4

let parse_hexacimal_charref nextf =
   let rec get_decimal acc state ucs4 =
      if ucs4 >= Uchar.of_char '0' && ucs4 <= Uchar.of_char '9' then
	 Lexer (get_decimal (acc * 16 + (ucs4 - Uchar.of_char '0')))
      else if ucs4 >= Uchar.of_char 'A' && ucs4 <= Uchar.of_char 'F' then
	 Lexer (get_decimal (acc * 16 + (ucs4 - Uchar.of_char 'A' + 10)))
      else if ucs4 >= Uchar.of_char 'a' && ucs4 <= Uchar.of_char 'f' then
	 Lexer (get_decimal (acc * 16 + (ucs4 - Uchar.of_char 'a' + 10)))
      else if ucs4 = Uchar.u_semicolon then
	 nextf state acc
      else
	 raise (LexerError "malformed character reference")
   in
      Lexer (get_decimal 0)

let parse_reference buf nextf state ucs4 =
   if ucs4 = Uchar.of_char '#' then
      Lexer (fun state ucs4 ->
		if ucs4 = Uchar.of_char 'x' then
		   parse_hexacimal_charref (fun state ucs4 ->
					       fencoder state buf ucs4;
					       Lexer nextf
					   )
		else
		   parse_decimal_charref 
		      (fun ucs4 -> 
			  fencoder state buf ucs4;
			  Lexer nextf
		      ) state ucs4
	    )
   else
      parse_name 
	 (fun name state ucs4 ->
	     if ucs4 = Uchar.u_semicolon then (
		(match name with
		    | "lt" -> Buffer.add_char buf '<'
		    | "gt" -> Buffer.add_char buf '>'
		    | "apos" -> Buffer.add_char buf '\''
		    | "quot" -> Buffer.add_char buf '"'
		    | "amp" -> Buffer.add_char buf '&'
		    | other ->
			 let ucs4 = state.process_entity other in
			    fencoder state buf ucs4
		);
		Lexer nextf
	     ) else
		raise (LexerError "invalid reference")
	 ) state ucs4
	 
let parse_text nextf state ucs4 =
   let buf = Buffer.create 30 in
   let rec get_text state ucs4 =
      if ucs4 = Uchar.u_lt then (
	 let text = Buffer.contents buf in
	    Buffer.clear buf;
	    nextf text ucs4
      ) else if ucs4 = Uchar.u_closebr then
	 Lexer (fun state ucs42 ->
		   if ucs42 = Uchar.u_lt then
		      let text = Buffer.contents buf in
			 Buffer.clear buf;
			 nextf text ucs42
		   else if ucs42 = Uchar.u_closebr then
		      Lexer (fun _state ucs43 ->
				if ucs43 = Uchar.u_gt then
				   raise (LexerError 
					     "']]>' is not allowed in text")
				else (
				   fencoder state buf ucs4;
				   fencoder state buf ucs42;
				   fencoder state buf ucs43;
				   Lexer get_text
				)
			    )
		   else (
		      fencoder state buf ucs4;
		      fencoder state buf ucs42;
		      Lexer get_text
		   )
	       )
      else if ucs4 = Uchar.u_amp then
	 Lexer (parse_reference buf get_text)
      else (
	 fencoder state buf ucs4;
	 Lexer get_text
      )
   in
      get_text state ucs4

let parse_whitespace nextf state ucs4 =
   let buf = Buffer.create 10 in
   let rec get_spaces state ucs4 =
      if Xmlchar.is_blank ucs4 then (
	 fencoder state buf ucs4;
	 Lexer get_spaces
      )
      else
	 let text = Buffer.contents buf in
	    Buffer.clear buf;
	    nextf text ucs4
   in
      fencoder state buf ucs4;
      Lexer get_spaces

let parse_comment nextf state ucs4 =
   let buf = Buffer.create 30 in
   if ucs4 = Uchar.u_dash then
      let rec get_comment state ucs41 =
	 if ucs41 = Uchar.u_dash then
	    Lexer (fun _state ucs42 ->
		      if ucs42 = Uchar.u_dash then
			 Lexer (fun _state ucs43 ->
				   if ucs43 = Uchar.u_gt then
				      let comment = Buffer.contents buf in
					 Buffer.clear buf;
					 nextf comment
				   else
				      raise (LexerError 
					"-- is not allowed inside comment")
			       )
		      else (
			 fencoder state buf ucs41;
			 fencoder state buf ucs42;
			 Lexer get_comment
		      )
		  )
	 else (
	    fencoder state buf ucs41;
	    Lexer get_comment
	 )
      in
	 Lexer get_comment
   else
      raise (LexerError "Malformed cooment")

let parse_string nextf state ucs4 =
   if ucs4 = Uchar.of_char '"' || ucs4 = Uchar.of_char '\'' then
      let buf = Buffer.create 30 in
      let rec get_text qt state ucs4 =
	 if ucs4 = qt then
	    let str = Buffer.contents buf in
	       Buffer.clear buf;
	       nextf str
	 else (
	    fencoder state buf ucs4;
	    Lexer (get_text qt)
	 )
      in
	 Lexer (get_text ucs4)
   else
      raise (LexerError "expected string")
	 
let parse_external_id nextf state ucs4 =
   if ucs4 = Uchar.of_char 'S' then
      accept_if "YSTEM" 
	 (after_blank (parse_string 
			  (fun str -> Lexer (nextf (Some (`System str))))))
   else if ucs4 = Uchar.of_char 'P' then
      accept_if "UBLIC"
	 (after_blank 
	     (parse_string 
		 (fun str -> 
		     Lexer 
			(after_blank 
			    (parse_string 
				(fun str2 ->
				    Lexer (nextf (Some (`Public (str, str2))))
				))))))
   else
      nextf None state ucs4

let parse_doctype nextf =
   accept_if "OCTYPE "
      (skip_blank 
	  (fun state ucs4 ->
	      parse_name (fun name state ucs4 ->
			     if ucs4 = Uchar.of_char '>' then
				nextf name None ""
			     else if Xmlchar.is_blank ucs4 then
				Lexer (skip_blank (parse_external_id
					  (fun ext ->
					  (fun state ucs4 ->
					      let buf = Buffer.create 30 in
					      let rec get_text state ucs4 =
						 if ucs4 = Uchar.of_char '>' then
						    let text = 
						       Buffer.contents buf in
						       Buffer.clear buf;
						       nextf name ext text
						 else (
						    fencoder state buf ucs4;
						    Lexer get_text
						 )
					      in
						 get_text state ucs4
					  )))
				      )
			     else
				raise (LexerError "bad doctype syntax")
			 ) state ucs4
	  )
      )
	 
let parse_attrvalue nextf =
   let buf = Buffer.create 30 in
   let rec get_value qt state ucs4 =
      if ucs4 = qt then
	 let value = Buffer.contents buf in
	    Buffer.clear buf;
	    Lexer (nextf value)
      else if ucs4 = Uchar.u_amp then
	 Lexer (parse_reference buf (get_value qt))
      else (
	 fencoder state buf ucs4;
	 Lexer (get_value qt)
      )
   in
      Lexer (fun state ucs4 ->
		if ucs4 = Uchar.u_apos || ucs4 = Uchar.u_quot then
		   Lexer (get_value ucs4)
		else
		   raise (LexerError "malformed attribute value")
	    )

let rec parse_attributes tag attrs nextf state ucs4 =
   if ucs4 = Uchar.u_gt then
      nextf tag attrs true
   else if ucs4 = Uchar.u_slash then
      Lexer (fun state ucs4 ->
		if ucs4 = Uchar.u_gt then
		   nextf tag attrs false
		else
		   raise (LexerError "invalid end of start tag")
	    )
   else 
      let smth state ucs4 =
	 if ucs4 = Uchar.u_gt then
	    nextf tag attrs true
	 else if ucs4 = Uchar.u_slash then
	    Lexer (fun state ucs4 ->
		      if ucs4 = Uchar.u_gt then
			 nextf tag attrs false
		      else
			 raise (LexerError "bad end of empty tag")
		  )
	 else 
	    parse_name
	       (fun name state ucs4 ->
		   if ucs4 = Uchar.u_eq then
		      parse_attrvalue
			 (fun value state ucs4 ->
			     parse_attributes tag 
				((name, value) :: attrs) nextf state ucs4
			 )
		   else
		      raise (LexerError "expected =")
	       ) state ucs4
      in
	 after_blank smth state ucs4

let parse_start_element nextf state ucs4 =
   parse_name (fun name -> parse_attributes name [] nextf) state ucs4

let parse_end_element nextf state ucs4 =
   parse_name
      (fun name ->
	  skip_blank (fun state ucs4 ->
			 if ucs4 = Uchar.u_gt then
			    nextf name
			 else
			    raise (LexerError "bad closing tag")
		     )) state ucs4
	 
let parse_cdata nextf state ucs4 =
   let buf = Buffer.create 30 in
      accept_if "CDATA["
	 (fun state ucs41 ->
	     let rec get_cdata state ch1 =
		if ucs41 = Uchar.of_char ']' then
		   Lexer (fun state ucs42 ->
			     if ucs42 = Uchar.of_char ']' then
				Lexer (fun state ucs43 ->
					  if ucs43 = Uchar.of_char '>' then
					     let cdata = Buffer.contents buf in
						Buffer.clear buf;
						nextf cdata
					  else
					     raise (LexerError "expected ]]>"))
			     else (
				fencoder state buf ucs41;
				fencoder state buf ucs42;
				Lexer get_cdata
			     )
			 )
		else (
		   fencoder state buf ucs41;
		   Lexer get_cdata
		)
	     in
		get_cdata state ucs4
	 )
	 
let parse_pi nextf state ucs4 =
   parse_name 
      (fun target state ucs4 ->
	  let buf = Buffer.create 30 in
	  let rec get_pi_content state ucs41 =
	     if ucs41 = Uchar.u_quest then
		Lexer (fun state ucs42 ->
			  if ucs42 = Uchar.u_gt then
			     let data = Buffer.contents buf in
				Buffer.clear buf;
				nextf target data
			  else (
			     fencoder state buf ucs41;
			     fencoder state buf ucs42;
			     Lexer get_pi_content
			  )
		      )
	     else (
		fencoder state buf ucs41;
		Lexer get_pi_content
	     )
	  in
	     after_blank get_pi_content state ucs4
      ) state ucs4
      
let parse_xmldecl nextf =
   let buf = Buffer.create 30 in
   let ascii_letter ucs4 = 
      ucs4 >= Uchar.of_char 'a' && ucs4 <= Uchar.of_char 'z' in
   let get_name nextf =
      let rec aux_name state ucs4 =
	 if ascii_letter ucs4 then (
            fencoder state buf ucs4;
            Lexer aux_name
         ) else (
            let name = Buffer.contents buf in
               Buffer.clear buf;
               nextf name ucs4
         )
      in
         Lexer aux_name
   in
   let get_value nextf =
      let rec aux_value qt state ucs4 =
         if ucs4 = qt then
            let value = Buffer.contents buf in
               Buffer.clear buf;
               Lexer (nextf value)
         else (
            fencoder state buf ucs4;
            Lexer (aux_value qt)
         )
      in
         Lexer (fun state ucs4 ->
		   if ucs4 = Uchar.of_char '"' || ucs4 = Uchar.of_char '\'' then
                      Lexer (aux_value ucs4)
		   else
                      raise (LexerError "expected attribute value")
               )
   in
   let rec parse_attributes attrs nextf state ucs4 =
      if ucs4 = Uchar.of_char '?' then
	 Lexer (fun state ucs4 ->
		   if ucs4 = Uchar.of_char '>' then
		      nextf attrs
		   else
		      raise (LexerError "Invalid syntax")
	       )
      else
         let smth state ucs4 =
            if ucs4 = Uchar.of_char '?' then
               nextf attrs
            else if ascii_letter ucs4 then (
               fencoder state buf ucs4;
               get_name (fun name ucs4 ->
                            if ucs4 = Uchar.of_char '=' then
                               get_value (fun value ucs4 ->
                                             parse_attributes 
                                                ((name, value) :: attrs) 
                                                nextf ucs4
                                         )
                            else
                               raise (LexerError "expected =")
                        )
            )
            else
               raise (LexerError "expected name")
         in
            after_blank smth state ucs4
   in
      accept_if "xml" (parse_attributes [] nextf)

let rec lexer nextf state ucs4 =
   if ucs4 = Uchar.u_lt then (
      Lexer (fun state ucs4 ->
		if ucs4 = Uchar.u_slash then
		   Lexer (parse_end_element
			     (fun name -> 
				 nextf (EndElement name);
				 Lexer (lexer nextf)))
		else if ucs4 = Uchar.u_quest then
		   Lexer (parse_pi
			     (fun target data -> 
				 nextf (Pi (target, data));
				 Lexer (lexer nextf)))
		else if ucs4 = Uchar.u_excl then
		   Lexer (fun state ucs4 ->
			     if ucs4 = Uchar.u_openbr then
				Lexer (parse_cdata
					  (fun cdata -> 
					      nextf (Cdata cdata);
					      Lexer (lexer nextf)))
			     else if ucs4 = Uchar.u_dash then
				Lexer (parse_comment 
					  (fun comment -> 
					      nextf (Comment comment);
					      Lexer (lexer nextf)))
			     else if ucs4 = Uchar.of_char 'D' then
				parse_doctype
				   (fun name ext_id str -> 
				       nextf (Doctype (name, ext_id, str));
				       Lexer (lexer nextf))
			     else
				raise (LexerError "unknown token <!.")
			 )
		else 
		   parse_start_element 
		      (fun name attrs flag ->
			  nextf (StartElement (name, (List.rev attrs)));
			  if not flag then
			     nextf (EndElement name);
			  Lexer (lexer nextf)) 
		      state ucs4
	    )
   )
   else
      if Xmlchar.is_blank ucs4 then
	 parse_whitespace (fun text ucs4 ->
			      nextf (Whitespace text);
			      lexer nextf state ucs4) state ucs4
      else
	 parse_text (fun text ucs4 -> 
			nextf (Text text);
			lexer nextf state ucs4)  state ucs4

let process_xmldecl unknown_encoding nextf attrs state =
   let version = 
      try List.assoc "version" attrs with Not_found -> "" in
      if version <> "1.0" then
	 raise (LexerError "unknown version of xmldecl");
      let encoding = try List.assoc "encoding" attrs with Not_found -> "" in
	 if encoding = "" then
	    Lexer (lexer nextf)
	 else
	    let up = String.uppercase encoding in
	       if state.encoding = up then
		  Lexer (lexer nextf)
	       else
		  let fdecoder =
		     match up with
			| "ASCII" | "US-ASCII" ->
			     Encoding.decode_ascii
			| "LATIN1" | "ISO-8859-1" ->
			     Encoding.decode_latin1
			| "UTF-8" ->
			     Encoding.decode_utf8
			| "UTF-16" | "UTF-16BE" ->
			     Encoding.decode_utf16 BE
			| "UTF-16LE" ->
			     Encoding.decode_utf16 BE
			| "UCS-4" | "UCS-4BE" ->
			     Encoding.decode_ucs4
			| "UCS-4LE" ->
			     Encoding.decode_ucs4le
			| other ->
			     unknown_encoding encoding
		  in
		     Switch (fdecoder, lexer nextf)

let rec start_lexer unknown_encoding nextf state ucs4 =
   if ucs4 = Uchar.u_lt then (
      Lexer (fun state ucs4 ->
		if ucs4 = Uchar.u_slash then
		   Lexer (parse_end_element 
			     (fun name -> 
				 nextf (EndElement name);
				 Lexer (lexer nextf)))
		else if ucs4 = Uchar.u_quest then
		   parse_xmldecl 
		      (fun attrs -> 
			  process_xmldecl unknown_encoding nextf attrs state)
		else if ucs4 = Uchar.u_excl then
		   Lexer (fun state c ->
			     if ucs4 = Uchar.u_openbr then
				Lexer (parse_cdata 
					  (fun cdata -> 
					      nextf (Cdata cdata);
					      Lexer (lexer nextf)))
			     else if ucs4 = Uchar.u_dash then
				Lexer (parse_comment 
					  (fun comment -> 
					      nextf (Comment comment);
					      Lexer (lexer nextf)))
			     else
				raise (LexerError "unknown token <!.")
			 )
		else 
		   parse_start_element 
		      (fun name attrs flag ->
			  nextf (StartElement (name, (List.rev attrs)));
			  if not flag then
			     nextf (EndElement name);
			  Lexer (lexer nextf)) state ucs4
	    )
   )
   else
      raise (LexerError "xml must not begin from text")

let create ?encoding 
      ~process_unknown_encoding
      ~process_entity
      ~process_production
      () =
   let rec fparser fdecoder flexer state strm =
      match Stream.peek strm with
	 | Some ch ->
	      Stream.junk strm;
	      (match fdecoder ch with
		  | F fdecoder ->
		       fparser fdecoder flexer state strm
		  | R (ucs4, fdecoder) ->
		       match flexer state ucs4 with
			  | Lexer flexer ->
			       fparser fdecoder flexer state strm
			  | Switch (fdecoder, flexer) ->
			       fparser fdecoder flexer state strm
			  | EndLexer ->
			       ()
	      )
	 | None ->
	      state.fparser <- fparser fdecoder flexer
   in
   let encoding, fparser =
      match encoding with
	 | None ->
	      let autodetect state strm =
		 let chs = Stream.npeek 4 strm in
		    if List.length chs < 4 then
		       raise TooFew;
		    let chs = Array.of_list chs in
		    let encoding, fdecoder = Encoding.autodetect_encoding 
		       (Uchar.of_char chs.(0)) (Uchar.of_char chs.(1)) 
		       (Uchar.of_char chs.(2)) (Uchar.of_char chs.(3))
		    in
		       state.encoding <- encoding;
		       fparser fdecoder 
			  (start_lexer process_unknown_encoding 
			      process_production)
			  state strm
	      in
		 "NONE", autodetect
	 | Some e ->
	      let encoding, fdecoder =
		 match e with
		    | Enc_UTF8 ->
			 "UTF-8", Encoding.decode_utf8
		    | Enc_UTF16 ->
			 "UTF-16", Encoding.decode_utf16 Encoding.BE
		    | Enc_ASCII ->
			 "ASCII", Encoding.decode_ascii
		    | Enc_Latin1 ->
			 "LATIN1", Encoding.decode_latin1
		    | Enc_UCS4 ->
			 "UCS-4", Encoding.decode_ucs4
	      in
		 encoding, fparser fdecoder 
		    (start_lexer process_unknown_encoding process_production)
   in
      {
	 encoding = encoding;
	 standalone = true;
	 base_uri = "";

	 fencoder = Encoding.encode_utf8;
	 fparser = fparser;
	 process_entity = process_entity;
      }

let parse state str start len = 
   let strm = 
      Stream.from (fun c -> if c+start < len then Some str.[c+start] else None)
   in
      state.fparser state strm