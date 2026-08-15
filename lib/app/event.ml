module Protocol = Owebview_protocol

let emit transport event value =
  Transport.emit transport
    (Protocol.Envelope.make ~kind:"event"
       (`Assoc
          [
            ("name", `String (Protocol.Event.name event));
            ("event", Protocol.Codec.encode (Protocol.Event.event event) value);
          ]))
