pipeline {
  agent any
  options {
    parallelsAlwaysFailFast()
  }
  stages {
    stage('Molecule Lint') {
      parallel {
        stage('Check Base') {
          steps {
            sh '''
              cd base
              molecule lint
            '''
          }
        }
      }
    }
    stage('Build docker image for Base') {
      when {
        not {
          branch 'master'
        }
      }
      steps {
        sh '''
          cd monitoring
          sudo molecule converge
        '''
      }
    }
  }
}
