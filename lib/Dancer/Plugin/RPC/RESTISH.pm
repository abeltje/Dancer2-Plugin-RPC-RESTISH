package Dancer::Plugin::RPC::RESTISH;
use v5.10;
use Dancer ':syntax';
use Dancer::Plugin;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

our $VERSION = '0.99_01';

use Dancer::RPCPlugin::CallbackResult;
use Dancer::RPCPlugin::DispatchFromConfig;
use Dancer::RPCPlugin::DispatchFromPod;
use Dancer::RPCPlugin::DispatchItem;
use Dancer::RPCPlugin::DispatchMethodList;
use Dancer::RPCPlugin::ErrorResponse;
use Dancer::RPCPlugin::FlattenData;
use Dancer::RPCPlugin::PluginNames;

Dancer::RPCPlugin::PluginNames->new->add_names('restish');

use Scalar::Util 'blessed';

# A char between the HTTP-Method and the REST-route
our $_HM_POSTFIX = '@';

my %dispatch_builder_map = (
    pod    => \&build_dispatcher_from_pod,
    config => \&build_dispatcher_from_config,
);

register restish => sub {
    my ($self, $endpoint, $arguments) = plugin_args(@_);

    my $publisher;
    given ($arguments->{publish} // 'config') {
        when (exists $dispatch_builder_map{$_}) {
            $publisher = $dispatch_builder_map{$_};
            $arguments->{arguments} = plugin_setting() if $_ eq 'config';
        }
        default {
            $publisher = $_;
        }
    }
    my $dispatcher = $publisher->($arguments->{arguments}, $endpoint);

    my $lister = Dancer::RPCPlugin::DispatchMethodList->new();
    $lister->set_partial(
        protocol => 'restish',
        endpoint => $endpoint,
        methods  => [ sort keys %{ $dispatcher } ],
    );

    my $code_wrapper = $arguments->{code_wrapper}
        ? $arguments->{code_wrapper}
        : sub {
            my $code = shift;
            my $pkg  = shift;
            $code->(@_);
        };
    my $callback = $arguments->{callback};

    debug("Starting restish-handler build: ", $lister);
    my $handle_call = sub {
        # we'll only handle requests that have either a JSON body or no body
        if (request->body && request->content_type ne 'application/json') {
            pass();
        }

        my $http_method  = uc(request->method);
        my $request_path = request->path;
        # method_name should exist...
        # we need to turn 'GET@some_resource/:id' into a regex that we can use
        # to match this request so we know what thing to call...
        (my $method_name = $request_path) =~ s{^$endpoint/}{};
        my $found_match;
        my @sorted_dispatch_keys = sort {
            # reverse length of the regex we use to match
            my ($am, $ar) = split(/\b$_HM_POSTFIX\b/, $a);
            $ar =~ s{/:\w+}{/[^/]+};
            my ($bm, $br) = split(/\b$_HM_POSTFIX\b/, $b);
            $br =~ s{/:\w+}{/[^/]+};
            length($br) <=> length($ar)
        } keys %$dispatcher;

        for my $plugin_route (@sorted_dispatch_keys) {
            my ($hm, $route) = split(/\b$_HM_POSTFIX\b/, $plugin_route, 2);
            next if uc($hm) ne $http_method;
            (my $route_match = $route) =~ s{/:\w+}{/[^/]+}g;
            debug("[restish_find_route(\U$hm\E => $method_name, $route ($route_match)");
            if ($method_name =~ m{^$route_match}) {
                $found_match = $plugin_route;
                last;
            }
        }

        if (! $found_match) {
            warning("$http_method => $request_path ($method_name) not found, pass()");
            pass();
        }

        content_type 'application/json';
        my $method_args = request->body
            ? from_json(request->body)
            : { };
        my $route_args = request->params('route') // { };
        my $query_args = request->params('query');

        # We'll merge method_args and route_args, where route_args win:
        $method_args = {
            %$method_args,
            %$route_args,
            %$query_args,
        };
        debug("[handling_restish_request('$request_path' via '$found_match')] ", $method_args);

        my Dancer::RPCPlugin::CallbackResult $continue = eval {
            $callback
                ? $callback->(request(), $method_name, $method_args)
                : callback_success();
        };

        my $response;
        if (my $error = $@) {
            $response = error_response(
                error_code    => 500,
                error_message => $error,
                error_data    => $method_args,
            )->as_restish_error;
        }
        elsif (!blessed($continue) || !$continue->isa('Dancer::RPCPlugin::CallbackResult')) {
            $response = error_response(
                error_code    => 500,
                error_message => "Internal error: 'callback_result' wrong class "
                               . blessed($continue),
                error_data    => $method_args,
            )->as_restish_error;
        }
        elsif (blessed($continue) && !$continue->success) {
            my $error_response = error_response(
                error_code    => $continue->error_code,
                error_message => $continue->error_message,
                error_data    => $method_args,
            );
            $error_response->http_status(403);
            $response = $error_response->as_restish_error;
        }
        else {
            my Dancer::RPCPlugin::DispatchItem $di = $dispatcher->{$found_match};
            my $handler = $di->code;
            my $package = $di->package;

            $response = eval {
                $code_wrapper->($handler, $package, $method_name, $method_args);
            };

            if (my $error = $@) {
                my $error_response = blessed($error) && $error->can('as_restish_error')
                    ? $error
                    : error_response(
                        error_code    => 500,
                        error_message => $error,
                        error_data    => $method_args,
                      );
                $response = $error_response->as_restish_error;
            }
            if (blessed($response) && $response->can('as_restish_error')) {
               $response = $response->as_restish_error;
            }
            elsif (blessed($response)) {
                $response = flatten_data($response);
            }
            debug("[handled_restish_response($request_path)] ", $response);
        }
        return to_json($response);
    };

    debug("setting routes (restish): $endpoint ", $lister);
    # split the keys in $dispatcher so we can register 'any' methods for all
    # the handler will know what to do...
    for my $dispatch_route (keys %$dispatcher) {
        my ($hm, $route) = split(/$_HM_POSTFIX/, $dispatch_route, 2);
        my $dancer_route = "$endpoint/$route";
        debug("[restish] registering `any $dancer_route` ($hm)");
        any $dancer_route, $handle_call;
    }

};

sub build_dispatcher_from_pod {
    my ($pkgs, $endpoint) = @_;
    debug("[build_dispatcher_from_pod]");
    return dispatch_table_from_pod(
        plugin   => 'restish',
        packages => $pkgs,
        endpoint => $endpoint,
    );
}

sub build_dispatcher_from_config {
    my ($config, $endpoint) = @_;
    debug("[build_dispatcher_from_config]");

    return dispatch_table_from_config(
        plugin   => 'restish',
        config   => $config,
        endpoint => $endpoint,
    );
}

register_plugin();
true;

=begin hack

=head2 Dancer::RPCPlugin::ErrorResponse->http_status($status)

This is a hack to extend the L<Dancer::RPCPlugin::ErrorResponse> class and add a
C<http_status> attribute. This attribute is used to set the http-status for the
response.

=head2 Dancer::RPCPlugin::ErrorResponse->as_restish_error()

This returns an error data structure and sets the http-status for the response.

=end hack

=cut

sub Dancer::RPCPlugin::ErrorResponse::http_status {
    my $self = shift;
    if (@_ == 1) {
        $self->{http_status} = $_[0];
    }
    return $self->{http_status};
}

sub Dancer::RPCPlugin::ErrorResponse::as_restish_error {
    my $self = shift;

    my $status = $self->http_status // 500;
    debug("[restish] Returning http-status: $status");
    status $status;
    return {
        error_code    => $self->error_code,
        error_message => $self->error_message,
        error_data    => $self->error_data,
    };
}

=head1 NAME

Dancer::Plugin::RPC::RESTISH - Simple plugin to implement a restish interface.


=head1 SYNOPSIS

In the Controler-bit:

    use Dancer::Plugin::RPC::RESTISH;
    restish '/endpoint' => {
        publish   => 'pod',
        arguments => ['MyProject::Admin'],
    };

and in the Model-bit (B<MyProject::Admin>):

    package MyProject::Admin;
    
    =for restish GET@ability/:id rpc_get_ability_details
    
    =cut
    
    sub rpc_get_ability_details {
        my %args = @_; # contains: {"id": 42}
        return {
            # datastructure
        };
    }
    1;

=head1 DESCRIPTION

RESTISH is an implementation of REST that lets you bind routes to code in the
style the rest of L<Dancer::Plugin::RPC> modules do.

This version only supports JSON as data serialisation.

=head2 restish '/base_path' => \%publisher_arguments

See L<Dancer::Plugin::RPC>, L<Dancer::Plugin::RPC::JSONRPC>,
L<Dancer::Plugin::RPC::RESTRPC>, L<Dancer::Plugin::RPC::XMLRPC> for more
information about the C<%publisher_arguments>.

=head2 Implement the routes for REST

The plugin registers Dancer-C<any> route-handlers for the C<base_path> +
C<method_path> and the route-handler looks for a data-handler that matches the path
and HTTP-method.

Method-paths can contain colon-prefixed parameters native to Dancer. These
parameters will be merged with the content.

Method-paths are prefixed by a HTTP-method followed by B<@>:

=over

=item publisher => 'config'

plugins:
    'RPC::RESTISH':
        '/rest':
            'MyProject::Admin':
                'GET@resources':       'get_all_resourses'
                'POST@resource':       'create_resource'
                'GET@resource/:id':    'get_resource'
                'PATCH@resource/:id':  'update_resource'
                'DELETE@resource/:id': 'delete_resource'

=item publisher => 'pod'

    =for restish GET@resources       get_all_resources /rest
    =for restish POST@resource       create_resource   /rest
    =for restish GET@resource/:id    get_resource      /rest
    =for restish PATCH@resource/:id  update_resource   /rest
    =for restish DELETE@resource/:id delete_resource   /rest

The third argument (the base_path) is optional.

=back

=head1 INTERNAL

=head2 build_dispatcher_from_config

Creates a (partial) dispatch table from data passed from the (YAML)-config file.

=head2 build_dispatcher_from_pod

Creates a (partial) dispatch table from data provided in POD.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See:

=over 4

=item * L<http://www.perl.com/perl/misc/Artistic.html>

=item * L<http://www.gnu.org/copyleft/gpl.html>

=back

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

=head1 COPYRIGHT

(c) MMXIX - Abe Timmerman <abeltje@cpan.org>

=cut
