use Crow;
use Crow::HTTP::Request;
use Crow::HTTP::Router;
use Test;

sub body-text(Crow::HTTP::Response $r) {
    $r.get-body-stream.list.map(*.decode('utf-8')).join
}

{
    my $app = route -> { }
    ok $app ~~ Crow::Transform, 'Route block with no routes gives back a Crow::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;
    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Empty route set gives a response';
        is $r.status, '404', 'Status code from empty route set is 404';
    }
}

throws-like { request }, X::Crow::HTTP::Router::OnlyInHandler, what => 'request',
    'Can only use request term inside of a handler';
throws-like { response }, X::Crow::HTTP::Router::OnlyInHandler, what => 'response',
    'Can only use response term inside of a handler';

{
    my $app = route {
        get -> {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('Hello, world'.encode('ascii'));
        }

        get -> 'about' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('We are the awesome'.encode('ascii'));
        }

        get -> 'company', 'careers' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('No jobs, kthxbai'.encode('ascii'));
        }
    }
    ok $app ~~ Crow::Transform, 'Route block with routes gives back a Crow::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes / correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'Hello, world', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</about>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes /about correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'We are the awesome', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</company/careers>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes /company/careers correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'No jobs, kthxbai', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</wat>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'No matching route gets a HTTP response';
        is $r.status, '404', 'Status code when no matching route is 404';
    }
}

done-testing;