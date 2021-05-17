//     Copyright 2020 Cedraro Andrea <a.cedraro@gmail.com>
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
//    limitations under the License.

#include <asio.hpp>
#include <cstddef>
#include <fstream>
#include <ios>
#include <iostream>
#include <memory>
#include <msgpack.hpp>
#include <string>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <utility>

#include "IdentifierCompleter.h"

constexpr uint32_t kREQUEST = 0;
constexpr uint32_t kRESPONSE = 1;
constexpr uint32_t kNOTIFICATION = 2;

template< uint32_t type_ = 0 >
struct rpc_msg
{
  uint32_t type = type_;

  MSGPACK_DEFINE( type );
};

template< typename Parameters >
struct rpc_request : rpc_msg< kREQUEST >
{
  rpc_request() = default;
  rpc_request( uint32_t id_, std::string method_, Parameters parameters )
    : id( id_ )
    , method( std::move( method_ ) )
    , params( std::move( parameters ) )
  {
  }

  uint32_t id = 0;
  std::string method;

  Parameters params;

  MSGPACK_DEFINE( type, id, method, params );
};

template< typename... Param >
struct nvim_call_function_payload
{
  nvim_call_function_payload( std::string f, Param&&... param )
    : function( std::move( f ) )
    , parameters( std::forward< Param >( param )... )
  {
  }

  std::string function;
  std::tuple< Param... > parameters;

  MSGPACK_DEFINE( function, parameters );
};

template< typename... Param >
struct nvim_exec_lua_payload
{
  nvim_exec_lua_payload( std::string c, Param&&... param )
    : code( std::move( c ) )
    , parameters( std::forward< Param >( param )... )
  {
  }

  std::string code;
  std::tuple< Param... > parameters;

  MSGPACK_DEFINE( code, parameters );
};

template< typename Error, typename Result >
struct rpc_response : rpc_msg< kRESPONSE >
{
  rpc_response() = default;

  rpc_response( uint32_t id_ )
    : id( id_ )
  {
  }

  rpc_response( uint32_t id_, Error error_ )
    : id( id_ )
    , error( std::move( error_ ) )
  {
  }

  uint32_t id = 0;
  Error error;
  Result result;

  MSGPACK_DEFINE( type, id, error, result );
};

template< typename Parameters >
struct rpc_notification : rpc_msg< kNOTIFICATION >
{
  std::string method;
  Parameters params;

  MSGPACK_DEFINE( type, method, params );
};

struct refresh_buffer_identifiers_notification
{
  std::string filetype;
  std::string filepath;
  msgpack::object identifiers;

  MSGPACK_DEFINE( filetype, filepath, identifiers );
};

struct complete_notification
{
  uint32_t id = 0;
  std::string filetype;
  std::string query;
  // std::optional< std::size_t > max_candidates;

  MSGPACK_DEFINE( id, filetype, query );
};

template< typename Derived >
class basic_rpc_client
{
public:
  basic_rpc_client( asio::io_context& context )
    : m_in( context, ::dup( STDIN_FILENO ) )
    , m_out( context, ::dup( STDOUT_FILENO ) )
    , m_log( "/Users/vheon/code/ycm.nvim/ycm.log", std::ios::out | std::ios::trunc )
  {
    asyn_read_rpcs();
  }

  template< typename Error, typename Result, typename WriteHandler >
  void async_send_response( const rpc_response< Error, Result >& response, WriteHandler&& h )
  {
    msgpack::sbuffer sbuf;
    msgpack::packer< msgpack::sbuffer > packer( sbuf );
    packer.pack( response );

    asio::async_write( m_out,
                       asio::const_buffer( sbuf.data(), sbuf.size() ),
                       std::forward< WriteHandler >( h ) );
  }

  // XXX(andrea): this is here just as a skeleton because I'm not sure I will need it
  template< typename Parameters, typename ResponseHandler >
  void async_send_request( const rpc_request< Parameters >& request, ResponseHandler&& h )
  {
    m_request_pending.insert( std::make_pair( request.id, std::forward< ResponseHandler >( h ) ) );

    msgpack::sbuffer sbuf;
    msgpack::packer< msgpack::sbuffer > packer( sbuf );
    packer.pack( request );

#ifdef DEBUG
    m_log << "msg ready to write = " << msgpack::unpack( sbuf.data(), sbuf.size() ).get() << std::endl;
#endif

    asio::async_write( m_out,
                       asio::const_buffer( sbuf.data(), sbuf.size() ),
                       [this, id = request.id]( asio::error_code ec, std::size_t bytes_transferred ) {
                         if ( ec )
                         {
#ifdef DEBUG
                           m_log << "A problem with the write accured" << std::endl;
#endif
                           m_request_pending.erase( id );
                         }
                       } );
  }

protected:
  void asyn_read_rpcs()
  {
    // XXX(andrea): this will ::realloc or ::malloc and ::copy in order to pack the
    // unparsed data to the start and `buffer` and `buffer_capacity` always
    // give the start of free buffer and how much is left.
    //
    // If we wanto to experiment with a slab allocator or simply a circular
    // buffer we should consider switching to a owned by us buffer and manage
    // memory in a smarter but more complex way. It require study the msgpack-c
    // API and implementation better.
    m_unpacker.reserve_buffer( 5 * 1024 * 1024 );

    asio::error_code ec;
    m_in.async_read_some( asio::buffer( m_unpacker.buffer(), m_unpacker.buffer_capacity() ),
                          [this]( asio::error_code ec, std::size_t bytes_transferred ) {
                            process_read( ec, bytes_transferred );
                          } );
  }

  void process_read( asio::error_code ec, std::size_t bytes_transferred )
  {
    if ( !ec )
    {
      m_unpacker.buffer_consumed( bytes_transferred );

      msgpack::object_handle handle;
      try
      {
        while ( m_unpacker.next( handle ) )
          handle_msg( handle.get() );

        asyn_read_rpcs();
      }
      catch ( msgpack::parse_error& e )
      {
        // XXX(andrea): we should probaly do the same as if an error occures
        m_log << e.what() << std::endl;
      }
      catch ( msgpack::type_error e )
      {
        // XXX(andrea): a type_error it means that there were problem converting a msgpack into some type but
        // the msg was received just fine. So maybe we should just log, ignore the msg and keep going.
        // XXX(andrea): this would be good to have test for.
        m_log << e.what() << std::endl;
      }
    }
    else if ( ec != asio::error::eof )
    {
      // XXX(andrea): we probably have to either:
      // - retry to send the message
      // - shutdown trying at least to communicate we're going away. Check Neovim doc or msgpack-rpc spec.
      m_log << ec.message() << std::endl;
    }
    else
    {
      // XXX(andrea): is this all it needs to shut down? should we do something
      // else? probably not from a communication standpoint since they close
      // the channel in the first place.
#ifdef DEBUG
      m_log << "stdin was closed" << std::endl;
#endif
    }
  }

  void handle_msg( const msgpack::object& msg )
  {
#ifdef DEBUG
    m_log << "msg = " << msg << std::endl;
#endif

    rpc_msg<> rpc;
    msg.convert( rpc );
    switch ( rpc.type )
    {
    case kREQUEST:
    {
      // XXX(andrea): rigth now we're using msgpack::object which having
      // reference semantics should just point to the memory of the
      // object_handle behind the `msg` object parameter. Just double check
      // that.
      basic_handle_request( msg.as< rpc_request< msgpack::object > >() );
    }
    break;
    case kRESPONSE:
    {
      handle_response( msg.as< rpc_response< msgpack::object, msgpack::object > >() );
    }
    break;
    case kNOTIFICATION:
    {
      basic_handle_notification( msg.as< rpc_notification< msgpack::object > >() );
    }
    break;
    default:
    {
      m_log << "Unknown rpc type received: " << rpc.type << std::endl;
    }
    break;
    }
  }

  template< typename Error, typename Result >
  void handle_response( const rpc_response< Error, Result >& response )
  {
    auto it = m_request_pending.find( response.id );
    if ( it == m_request_pending.end() )
    {
      m_log << "A response for a unknown request came in" << std::endl;
      return;
    }
    rpc_response_handler_t h = it->second;
    m_request_pending.erase( it );

    h( response );
  }

  template< typename Parameters >
  void basic_handle_request( const rpc_request< Parameters >& request )
  {
    static_cast< Derived* >( this )->handle_request( request );
  }

  void basic_handle_notification( const rpc_notification< msgpack::object >& notification )
  {
    static_cast< Derived* >( this )->handle_notification( notification );
  }

protected:
  std::ofstream m_log;

private:
  asio::posix::stream_descriptor m_in;
  asio::posix::stream_descriptor m_out;

  msgpack::unpacker m_unpacker;

  using rpc_response_handler_t =
      std::function< void( const rpc_response< msgpack::object, msgpack::object >& ) >;
  std::unordered_map< uint32_t, rpc_response_handler_t > m_request_pending;
};

namespace ycm = YouCompleteMe;

class ycm_rpc_client : public basic_rpc_client< ycm_rpc_client >
{
public:
  ycm_rpc_client( asio::io_context& context )
    : basic_rpc_client< ycm_rpc_client >( context )
    , m_next_id( 0 )
  {
  }

  template< typename Parameters >
  void handle_request( const rpc_request< Parameters >& request )
  {
#ifdef DEBUG
    m_log << "A request for: " << request.method << " came in" << std::endl;
#endif
  }

  void handle_notification( const rpc_notification< msgpack::object >& notification )
  {
#ifdef DEBUG
    m_log << "A notification for: " << notification.method << " came in" << std::endl;
#endif
    if ( notification.method == "refresh_buffer_identifiers" )
    {
      handle_refresh_buffer_identifiers(
          notification.params.as< refresh_buffer_identifiers_notification >() );
    }
    else if ( notification.method == "complete" )
    {
      handle_complete( notification.params.as< complete_notification >() );
    }
  }

  void handle_refresh_buffer_identifiers( const refresh_buffer_identifiers_notification& notification )
  {
    auto candidates = notification.identifiers.as< std::vector< std::string > >();
    // XXX(andrea): in the commit we're at
    // ClearForFileAndAddIdentifiersToDatabase takes the filetype and filepath
    // as non-const std::string refs. Look this better and see what should we
    // do... maybe just get the notification as a copy? we could move it in
    // since it is already a temporary.
    std::string filetype = notification.filetype;
    std::string filepath = notification.filepath;
    m_completer.ClearForFileAndAddIdentifiersToDatabase( std::move( candidates ), filetype, filepath );
  }

  template< typename Parameters >
  rpc_request< Parameters > create_rpc_request( std::string method, Parameters&& parameters )
  {
    return rpc_request< Parameters >{ m_next_id++,
                                      std::move( method ),
                                      std::forward< Parameters >( parameters ) };
  }

  template < typename... Parameters >
  auto create_nvim_exec_lua_request( std::string body, Parameters&&... parameters )
  {
    return create_rpc_request(
        "nvim_exec_lua",
        nvim_exec_lua_payload< Parameters... >{ std::move( body ),
                                                std::forward< Parameters >( parameters )... } );
  }

  void handle_complete( const complete_notification& notification )
  {
#ifdef DEBUG
    m_log << "[handle_complete] query: " << notification.query << " for filetype: " << notification.filetype
          << std::endl;
#endif
    auto candidates = m_completer.CandidatesForQueryAndType( notification.query, notification.filetype );
    async_send_request( create_nvim_exec_lua_request( "require'ycm'.show_candidates(...)",
                                                      notification.id,
                                                      std::move( candidates ) ),
                        [this]( const rpc_response< msgpack::object, msgpack::object >& response ) {
                          if ( response.error.type != msgpack::type::NIL )
                          {
                            m_log << "Error with message sent: " << response.error << std::endl;
                            return;
                          }
                        } );
  }

  uint32_t m_next_id;
  ycm::IdentifierCompleter m_completer;
};

int main( int argc, char* argv[] )
{
  asio::io_context context;
  ycm_rpc_client client( context );

  context.run();

  return 0;
}
