use Cro::TCP;
use Cro::HTTP2::Frame;
use Cro::Transform;

class Cro::HTTP2::FrameParser does Cro::Transform {
    method consumes() { Cro::TCP::Message }
    method produces() { Cro::HTTP2::Frame }

    method transformer(Supply:D $in) {
        supply {
            my enum Expecting <Header Payload>;

            my $buffer = Buf.new;
            my $length;
            my ($type, $flags, $sid);
            my Expecting $expecting = Header;

            whenever $in -> Cro::TCP::Message $packet {
                my $data = $buffer ~ $packet.data;
                $buffer = Buf.new;

                loop {
                    $_ = $expecting;

                    when Header {
                        if $data.elems < 9 {
                            $buffer.append: $data; last;
                        } else {
                            $length = ($data[0] +< 16) +| ($data[1] +< 8) +| $data[2];
                            $type = $data[3];
                            $flags = $data[4];
                            $sid = ($data[5] +< 24) +| ($data[6] +< 16) +| ($data[7] +< 8) +| $data[8];
                            $data .= subbuf(9); # Header is parsed;
                            $expecting = Payload; next;
                        }
                    }
                    when Payload {
                        if $data.elems >= $length {
                            emit payload($type, $data, $length, :$flags, stream-identifier => $sid);
                            $data .= subbuf($length);
                            $expecting = Header; next if $data.elems > 0;
                        } else {
                            $buffer.append: $data;
                        }
                    }
                }
            }
        }
    }

    my multi sub payload(0, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $padding-length = $data[0] if $padded;
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        Cro::HTTP2::Frame::Data.new(padding-length => ($padding-length // UInt),
                                    data => utf8.new($payload), |%header);
    }
    my multi sub payload(1, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $padding-length = $data[0] if $padded;
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        my ($dependency, $weight, $headers);
        my $exclusive = $payload[0] +& (1 +< 7) != 0;
        if $exclusive {
            $dependency = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
            $weight = $data[4];
        }
        $headers = utf8.new: $payload.subbuf($exclusive ?? 5 !! 0, $length);
        Cro::HTTP2::Frame::Headers.new(padding-length => $padding-length // UInt,
                                       dependency => $dependency // UInt,
                                       weight => $weight // UInt,
                                       :$exclusive, :$headers, |%header);
    }
    my multi sub payload(2, Buf $data is rw, $length, *%header) {
        my $exclusive = $data[0] +& (1 +< 7) != 0;
        $data[0] = $data[0] +& 0x79; # Reset first bit.
        my $dep = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
        my $weight = $data[4];
        Cro::HTTP2::Frame::Priority.new(:$exclusive, dependency => $dep, :$weight, |%header);
    }
    my multi sub payload(3, Buf $data is rw, $length, *%header) {
        my $error-code = ($data[0] +< 24) +| ($data[1] +< 16) +| ($data[2] +< 8) +| $data[3];
        $error-code = ErrorCode($error-code) // INTERNAL_ERROR;
        Cro::HTTP2::Frame::RstStream.new(:$error-code, |%header);
    }
    my multi sub payload(4, Buf $data is rw, $length, *%header) {
        my $sets = $length div 6;
        my @settings;

        for 0...($sets-1) {
            my $identifier = ($data[$_*6 + 0] +< 8) +| $data[$_*6 + 1];
            my $value = ($data[$_*6 + 2] +< 24) +| ($data[$_*6 + 3] +< 16) +| ($data[$_*6 + 4] +< 8) +| $data[$_*6 + 5];
            @settings.append: $identifier => $value;
        }
        Cro::HTTP2::Frame::Settings.new(:@settings, |%header);
    }
    my multi sub payload(5, Buf $data is rw, $length, *%header) {
        my $padded = %header<flags> +& 0x8 == 0x8;
        my $padding-length = $data[0] if $padded;
        my $payload = $padded
        # `-1` here is first byte that is padding-length
        ?? $data.subbuf(1, $length - $padding-length - 1)
        !! $data.subbuf(0, $length);
        my ($promised-sid, $headers);

        $data[0] = $data[0] +& 0x79; # Reset first bit.
        $promised-sid = ($data[0] +< 24)
                     +| ($data[1] +< 16)
                     +| ($data[2] +< 8)
                     +|  $data[3];
        $headers = utf8.new: $payload.subbuf(4, $length);
        Cro::HTTP2::Frame::PushPromise.new(padding-length => ($padding-length // UInt),
                                           :$promised-sid, :$headers, |%header);
    }
    my multi sub payload(6, Buf $data is rw, $length, *%header) {
        my $payload = Blob.new($data.subbuf(0, $length));
        Cro::HTTP2::Frame::Ping.new(:$payload, |%header);
    }
    my multi sub payload(7, Buf $data is rw, $length, *%header) {
        my ($last-sid, $error-code, $debug);
        $data[0] = $data[0] +& 0x79; # Reset first bit.
        $last-sid = ($data[0] +< 24)
                 +| ($data[1] +< 16)
                 +| ($data[2] +< 8)
                 +|  $data[3];
        $error-code = ($data[4] +< 24)
                   +| ($data[5] +< 16)
                   +| ($data[6] +< 8)
                   +|  $data[7];
        $error-code = ErrorCode($error-code) // INTERNAL_ERROR;
        $debug = utf8.new: $data.subbuf(8, $length);
        Cro::HTTP2::Frame::Goaway.new(:$last-sid, :$error-code, :$debug, |%header);
    }
    my multi sub payload(8, Buf $data is rw, $length, *%header) {
        my $increment = ($data[0] +< 24)
                 +| ($data[1] +< 16)
                 +| ($data[2] +< 8)
                 +|  $data[3];
        Cro::HTTP2::Frame::WindowUpdate.new(:$increment, |%header);
    }
    my multi sub payload(9, Buf $data is rw, $length, *%header) {
        my $headers = utf8.new: $data.subbuf(0, $length);
        Cro::HTTP2::Frame::Continuation.new(:$headers, |%header);
    }
}
