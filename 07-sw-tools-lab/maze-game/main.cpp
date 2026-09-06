

#include "ofMain.h"
#include "ofApp.h"

//--------------------------------------------------------------
// to change options for console window (Visual Studio)
//
// Properties > Linker > System > Subsystem
//    for console : Windows (/SUBSYSTEM:CONSOLE)
//
//    for Window : Windows (/SUBSYSTEM:WINDOWS)
//
// Click APPLY and OK. Then make changes to Main as below
//--------------------------------------------------------------

// for default console
//========================================================================
int main()
{
//
// for window without console
//========================================================================
// int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nShowCmd) {
	ofSetupOpenGL(640, 480, OF_WINDOW);			// <-------- setup the GL context
	//ofSetupOpenGL(1024, 768, OF_WINDOW);
	// this kicks off the running of my app
	// can be OF_WINDOW or OF_FULLSCREEN
	// pass in width and height too:
	ofRunApp( new ofApp());  // ofApp 객체를 생성하고 애플리케이션을 실행
}
