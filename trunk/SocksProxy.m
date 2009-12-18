/*
 #  SOCKS - SOCKS Proxy for iPhone
 #  Copyright (C) 2009 Ehud Ben-Reuven
 #  udi@benreuven.com
 #
 # This program is free software; you can redistribute it and/or
 # modify it under the terms of the GNU General Public License
 # as published by the Free Software Foundation version 2.
 #
 # This program is distributed in the hope that it will be useful,
 # but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 # GNU General Public License for more details.
 #
 # You should have received a copy of the GNU General Public License
 # along with this program; if not, write to the Free Software
 # Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,USA.
 */
#import "SocksProxy.h"

#include <CFNetwork/CFNetwork.h>

#include <sys/socket.h>
#include <netinet/in.h>

@interface SocksProxy ()

// Properties that don't need to be seen by the outside world.

@property (nonatomic, retain)   NSInputStream *     receivenetworkStream;
@property (nonatomic, retain)   NSOutputStream *    sendnetworkStream;
@property (nonatomic, retain)   NSOutputStream *    remoteSendNetworkStream;
@property (nonatomic, retain)   NSInputStream *     remoteReceiveNetworkStream;
@property (nonatomic, readonly) uint8_t *           sendbuffer;
@property (nonatomic, assign)   size_t              sendbufferOffset;
@property (nonatomic, assign)   size_t              sendbufferLimit;
@property (nonatomic, readonly) uint8_t *           receivebuffer;
@property (nonatomic, assign)   size_t              receivebufferOffset;
@property (nonatomic, assign)   size_t              receivebufferLimit;
@property (nonatomic, assign)   NSUInteger			protocolLocation;
@property (nonatomic, retain)   NSString *			remoteName;

@end

@implementation SocksProxy

#pragma mark * Core transfer code

// This is the code that actually does the networking.

@synthesize receivenetworkStream   = _receivenetworkStream;
@synthesize sendnetworkStream   = _sendnetworkStream;
@synthesize remoteSendNetworkStream      = _remoteSendNetworkStream;
@synthesize remoteReceiveNetworkStream      = _remoteReceiveNetworkStream;
@synthesize sendbufferOffset    = _sendbufferOffset;
@synthesize sendbufferLimit     = _sendbufferLimit;
@synthesize receivebufferOffset    = _receivebufferOffset;
@synthesize receivebufferLimit     = _receivebufferLimit;
@synthesize protocolLocation  = _protocolLocation;
@synthesize delegate;
@synthesize remoteName			= _remoteName;
// Because buffer is declared as an array, you have to use a custom getter.  
// A synthesised getter doesn't compile.

- (uint8_t *)sendbuffer
{
    return self->_sendbuffer;
}
- (uint8_t *)receivebuffer
{
    return self->_receivebuffer;
}


- (BOOL)isSendingReceiving
{
    return (self.receivenetworkStream != nil) || (self.sendnetworkStream != nil);
}

- (void)startSendReceive:(int)fd
{
    CFReadStreamRef     readStream;
    CFWriteStreamRef    writeStream;
    
    assert(fd >= 0);

    assert(self.receivenetworkStream == nil);      // can't already be receiving
    assert(self.remoteSendNetworkStream == nil);         // ditto
    assert(self.remoteReceiveNetworkStream == nil);         // ditto
	self.protocolLocation=0;
	
    // Open a stream based on the existing socket file descriptor.  Then configure 
    // the stream for async operation.

    CFStreamCreatePairWithSocket(NULL, fd, &readStream, &writeStream);
    assert(readStream != NULL);
    
    self.receivenetworkStream = (NSInputStream *) readStream;
    self.sendnetworkStream = (NSOutputStream *) writeStream;
    
    CFRelease(readStream);
    CFRelease(writeStream);

    [self.receivenetworkStream setProperty:(id)kCFBooleanTrue forKey:(NSString *)kCFStreamPropertyShouldCloseNativeSocket];
    [self.sendnetworkStream    setProperty:(id)kCFBooleanTrue forKey:(NSString *)kCFStreamPropertyShouldCloseNativeSocket];

    self.receivenetworkStream.delegate = self;
    self.sendnetworkStream.delegate = self;
    [self.receivenetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [self.sendnetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    [self.receivenetworkStream open];
    [self.sendnetworkStream open];

	// Tell the UI we're receiving.
	
	[self.delegate _sendreceiveDidStart];
}

- (void)stopSendReceiveWithStatus:(NSString *)statusString
{
    if (self.receivenetworkStream != nil) {
        self.receivenetworkStream.delegate = nil;
        [self.receivenetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        [self.receivenetworkStream close];
        self.receivenetworkStream = nil;
    }
	self.receivebufferOffset = 0;
    self.receivebufferLimit  = 0;

    if (self.sendnetworkStream != nil) {
        [self.sendnetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.sendnetworkStream.delegate = nil;
        [self.sendnetworkStream close];
        self.sendnetworkStream = nil;
    }
	self.sendbufferOffset = 0;
    self.sendbufferLimit  = 0;
		
	//remote send
    if (self.remoteSendNetworkStream != nil) {
        [self.remoteSendNetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.remoteSendNetworkStream.delegate = nil;
        [self.remoteSendNetworkStream close];
        self.remoteSendNetworkStream = nil;
    }

	//remote receive
    if (self.remoteReceiveNetworkStream != nil) {
        [self.remoteReceiveNetworkStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.remoteReceiveNetworkStream.delegate = nil;
        [self.remoteReceiveNetworkStream close];
        self.remoteReceiveNetworkStream = nil;
    }

	self.remoteName=nil;
	
    [self.delegate _sendreceiveDidStopWithStatus:statusString];
}

- (void)sendBuffer
{
	if (![self.sendnetworkStream hasSpaceAvailable])
		return;
	if (self.sendbufferOffset == self.sendbufferLimit) return;
	NSInteger   bytesWritten=self.sendbufferLimit - self.sendbufferOffset;
#if __DEBUG__
	NSLog(@"write P>C %d",bytesWritten);
#endif
	bytesWritten = [self.sendnetworkStream write:&self.sendbuffer[self.sendbufferOffset] maxLength:bytesWritten];
#if __DEBUG__
	NSLog(@"actually write %d",bytesWritten);
#endif
	assert(bytesWritten != 0);
	if (bytesWritten == -1) {
		[self stopSendReceiveWithStatus:@"Network write error"];
	} else {
		self.sendbufferOffset += bytesWritten;
	}
	if (self.sendbufferOffset==self.sendbufferLimit) {
		self.sendbufferOffset=0;
		self.sendbufferLimit=0;
	}
}
- (void)sendremoteBuffer
{
	if (![self.remoteSendNetworkStream hasSpaceAvailable])
		return;

	if (self.receivebufferOffset == self.receivebufferLimit) return;
	NSInteger   bytesWritten;
	bytesWritten = [self.remoteSendNetworkStream write:&self.receivebuffer[self.receivebufferOffset]
								maxLength:self.receivebufferLimit - self.receivebufferOffset];
	assert(bytesWritten != 0);
	if (bytesWritten == -1) {
		[self stopSendReceiveWithStatus:@"Remote network write error"];
	} else {
		self.receivebufferOffset += bytesWritten;
	}
	if (self.receivebufferOffset==self.receivebufferLimit) {
		self.receivebufferOffset=0;
		self.receivebufferLimit=0;
	}
}


-(uint)sendData:(uint8_t *)buf size:(uint)n
{
	if (n>kSendBufferSize-self.sendbufferLimit)
		n = kSendBufferSize-self.sendbufferLimit;
	if (n>0) {
		memcpy(&(self.sendbuffer[self.sendbufferLimit]), buf, (size_t)n);
		self.sendbufferLimit+=n;
	}
	return n;
}

- (void)socksProtocol
{
	
	NSInteger       bytesRead;
	
	// [self.delegate _updateStatus:@"Receiving"];
	
	// Pull some data off the network.
	
	bytesRead = [self.receivenetworkStream read:&self.receivebuffer[self.receivebufferLimit]
									  maxLength:kReceiveBufferSize-self.receivebufferLimit];
	if (bytesRead == -1) {
		[self stopSendReceiveWithStatus:@"Network read error"];
		return;
	}
	if (bytesRead == 0) {
		[self stopSendReceiveWithStatus:nil];
		return;
	}
	
	self.receivebufferLimit+=bytesRead;
	
	NSUInteger lastProtocolLocation = -1;
	while (self.receivebufferLimit>self.receivebufferOffset) {
		// if the protocol did not advance then it is an indication that we dont
		// have enough data in self.receivebuffer
		// we should exit this handler and wait for it to be called again with more
		if(lastProtocolLocation == self.protocolLocation)
			break;
		lastProtocolLocation=self.protocolLocation;
		
		uint8_t *s=self.receivebuffer+self.receivebufferOffset;
		uint8_t *e=self.receivebuffer+self.receivebufferLimit;
		
#if __DEBUG__
		NSLog(@"protocol %d %d",self.protocolLocation,e-s);
#endif
		switch (self.protocolLocation) {
			case 0: {// The initial greeting from the client is
				// SOCKS protocl version
				if(e-s<1) break;
				uint8_t socks_version = *s++;
				if (socks_version!=5) {
					[self stopSendReceiveWithStatus:@"Unsupported SOCKS protocol"];
					break;								
				}
				
				//number of authentication methods supported
				if (e-s<1) break;
				uint8_t nauth = *s++;
				
				//authentication methods
				if(e-s<nauth) break;
				uint8_t *auth = s;
				s+=nauth;
				
				int i;
				for (i=0; i<nauth; i++)
					if (auth[i]==0)
						break;
				
				uint8_t buf[2];
				buf[0]= socks_version;
				if(i<nauth) {
					buf[1]= auth[i];
				} else {
					buf[1] = 0xff;
#if __DEBUG__
					NSLog(@"unsupported authentication %d %d",auth[0],nauth);
#endif
				}
				
				if ([self sendData:buf size:2] != 2) {
					[self stopSendReceiveWithStatus:@"Cant send reply"];
					break;								
				}
				[self sendBuffer];
				
				//advance buffer/protocol
				self.receivebufferOffset=s-self.receivebuffer;
				if (i<nauth) {
					self.protocolLocation++;
				} else {
					self.protocolLocation=0;
				}
			} break;
			case 1: { // client's connection request
				uint8_t rc=0;
				// SOCKS protocl version
				if(e-s<3) break;
				uint8_t socks_version = *s++;
				if (socks_version!=5) {
					[self stopSendReceiveWithStatus:@"Unsupported SOCKS protocol"];
					break;								
				}
				//command
				uint8_t command = *s++;
				//reserverd
				if (*s++ != 0) {
					[self stopSendReceiveWithStatus:@"bad command"];
					break;								
				}
				//address type
				if(e-s<1) break;
				uint8_t *addrstart=s;
				uint8_t addr_type = *s++;
				NSString *addr=nil;
				//address
				if (addr_type==1) {
					if(e-s<4) break;
					in_addr_t ipaddr = ntohl(*s);
					s+=4;
					addr = [NSString stringWithFormat:@"%d.%d.%d.%d",
								 0xff&(ipaddr>>24),
								 0xff&(ipaddr>>16),
								 0xff&(ipaddr>>8),
								 0xff&(ipaddr>>0)
								 ];
				} else if(addr_type==3) {
					if(e-s<1) break;
					size_t n=*s++;
					char saddr[2048];
					if (n>=sizeof(saddr)-1) {
						memcpy(saddr,"too long",9);
						rc=1;
					} else {
						memcpy(saddr, s, n);
					}
					s+=n;
					saddr[n]=0;
					addr=[NSString stringWithCString:saddr encoding:[NSString defaultCStringEncoding]];
				} else {//address type not supported
					rc=8;
				}

				//port
				if(e-s<2) break;
				int port = ntohs(*(ushort *)s);
				s+=2;
				
				//execute the command
				if (addr) {
					self.remoteName=[NSString stringWithFormat:@"%@:%d",addr,port];
					[self.delegate _updateStatus:self.remoteName];
				}
				if (command == 1) {
					CFHostRef host;
					if(!rc){
						host = CFHostCreateWithName(NULL,(CFStringRef)addr);
						if (host == NULL) {
							rc=4; //host unreachable								
						}
					}
					CFReadStreamRef     readStream;
					CFWriteStreamRef    writeStream;
					if(!rc) {
						(void) CFStreamCreatePairWithSocketToCFHost(NULL,host,port, &readStream, &writeStream);
						if (!readStream || !writeStream) {
							rc=5;// connection refused by destination host
						}
						CFRelease(host);
					}
					if(!rc) {
						self.remoteReceiveNetworkStream = (NSInputStream *)readStream;
						CFRelease(readStream);
						self.remoteReceiveNetworkStream.delegate = self;
						[self.remoteReceiveNetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
						[self.remoteReceiveNetworkStream open];
						
						self.remoteSendNetworkStream = (NSOutputStream *)writeStream;
						CFRelease(writeStream);
						self.remoteSendNetworkStream.delegate = self;
						[self.remoteSendNetworkStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
						[self.remoteSendNetworkStream open];
					}
				} else {//command not supported / protocol error
					rc = 7;
				}

				
				//send a reply
				uint8_t buf[3];
				buf[0]=socks_version;
				buf[1]=rc;
				buf[2]=0;//reserved

				if ([self sendData:buf size:3] != 3) {
					[self stopSendReceiveWithStatus:@"Cant send reply 1"];
					break;								
				}
				uint n=s-addrstart;
				if ([self sendData:addrstart size:n] != n) {
					[self stopSendReceiveWithStatus:@"Cant send reply 2"];
					break;								
				}
				[self sendBuffer];
				
				//advance buffer/protocol
				self.receivebufferOffset=s-self.receivebuffer;
				if(!rc)
					self.protocolLocation++;
				else {
					self.protocolLocation=0;
				}

				//send any data we already have to remote host
				if(!rc)
					[self sendremoteBuffer];
			} break;
			default: {
				[self sendremoteBuffer];
			} break;
		}
	}
	if (self.receivebufferLimit==self.receivebufferOffset) {
		self.receivebufferOffset=0;
		self.receivebufferLimit=0;
	}
}

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
    // An NSStream delegate callback that's called when events happen on our 
    // network stream.
{
#if __DEBUG__
	NSStream *streamName;
	// C-Client (laptop) P-Proxy (iPhone) S-Server (remote server)
	if (aStream == self.receivenetworkStream) {
		streamName = @"C>P";
	} else if (aStream == self.sendnetworkStream) {
		streamName = @"P>C";
	} else if (aStream == self.remoteReceiveNetworkStream) {
		streamName = @"S>P";
	} else if (aStream == self.remoteSendNetworkStream) {
		streamName = @"P>S";
	} else {
		streamName = @"Unknown";
	}
	if (self.remoteName) {
		streamName = [NSString stringWithFormat:@"%@ %@",streamName,self.remoteName]; 
	}
#endif

    switch (eventCode) {
        case NSStreamEventOpenCompleted: {
#if __DEBUG__
			NSLog(@"Open %@",streamName);
#endif
            [self.delegate _updateStatus:@"Opened connection"];
        } break;
        case NSStreamEventHasBytesAvailable: {
#if __DEBUG__
			NSLog(@"Receive %@",streamName);
#endif			
			if (aStream == self.remoteReceiveNetworkStream) {
				// data is coming from the remote site
				NSInteger       bytesRead;
				bytesRead = [self.remoteReceiveNetworkStream read:&self.sendbuffer[self.sendbufferLimit]
												  maxLength:kSendBufferSize-self.sendbufferLimit];
				if (bytesRead == -1) {
					[self stopSendReceiveWithStatus:@"Remote network read error"];
				} else if (bytesRead == 0) {
					[self stopSendReceiveWithStatus:nil];
					break;
				} else {
					self.sendbufferLimit+=bytesRead;
					[self sendBuffer];
				}
				break;
			} else if (aStream == self.receivenetworkStream) {
				[self socksProtocol];
            }
        } break;
        case NSStreamEventHasSpaceAvailable: {
#if __DEBUG__
			NSLog(@"Send %@",streamName);
#endif			
			if (aStream == self.remoteSendNetworkStream) {
				//remote host is ready to receive data
				[self sendremoteBuffer];
				break;
			} else if (aStream == self.sendnetworkStream) {
				//local host is ready to receive data
				[self sendBuffer];
			}
        } break;
        case NSStreamEventErrorOccurred: {
#if __DEBUG__
			NSLog(@"Error %@",streamName);
#endif			
            [self stopSendReceiveWithStatus:@"Stream open error"];
        } break;
        case NSStreamEventEndEncountered: {
            // ignore
#if __DEBUG__
			NSLog(@"End %@",streamName);
#endif			
        } break;
        default: {
            assert(NO);
        } break;
    }
}
@end
