;;;; -*- mode: lisp -*-
;;;; $Id: cl-xmpp.asd,v 1.4 2005/10/31 21:07:14 eenge Exp $
;;;; $Source: /project/cl-xmpp/cvsroot/cl-xmpp/cl-xmpp.asd,v $

;;;; See the LICENSE file for licensing information.

(in-package #:cl-user)

(defpackage #:cl-xmpp-system
    (:use #:cl #:asdf))

(in-package #:cl-xmpp-system)

(defsystem cl-xmpp
    :name "cl-xmpp"
    :author "Erik Enge"
    :version "0.0.1"
    :licence "MIT"
    :description "Common Lisp XMPP client implementation"
    :depends-on (#+sbcl :sb-bsd-sockets :trivial-sockets :cxml :ironclad)
    :components ((:file "package")
                 (:file "variable"
                        :depends-on ("package"))
                 (:file "utility"
                        :depends-on ("variable"))
		 (:file "cxml"
			:depends-on ("utility"))
		 (:file "result"
			:depends-on ("cxml"))
                 (:file "cl-xmpp"
                        :depends-on ("result"))))

